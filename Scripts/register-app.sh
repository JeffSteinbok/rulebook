#!/usr/bin/env bash
#
# Creates the Entra ID (Azure AD) app registration RuleBook needs.
#
#   az login                       # once, as someone who can register apps
#   ./Scripts/register-app.sh
#
# Creates a PUBLIC CLIENT registration — no client secret, which is what both
# the device code flow (CLI) and MSAL on iOS require.

set -euo pipefail

APP_NAME="${APP_NAME:-Rulebook}"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-net.steinbok.Rulebook}"

# Delegated Microsoft Graph scopes. MailboxSettings.ReadWrite is the one that
# grants access to /me/mailFolders/inbox/messageRules; drop it to
# MailboxSettings.Read for a read-only build.
SCOPES=(
  "MailboxSettings.ReadWrite"
  # Rules reference folders by opaque id; resolving those into names reads
  # /me/mailFolders, a separate resource with its own permission.
  #
  # Choosing a destination folder reads /me/mailFolders, so any rule that
  # files mail depends on this. MailboxFolder.Read would be the precise scope —
  # folders only, no messages — but it is work/school only: via /consumers or
  # /common it fails with AADSTS70011, and /common must satisfy both audiences.
  # Personal accounts are the expected audience here, so Mail.ReadBasic it is.
  #
  # Check any scope against an authority with:
  #   curl -s -X POST https://login.microsoftonline.com/<authority>/oauth2/v2.0/devicecode \\
  #     -d client_id=$APP_ID --data-urlencode "scope=MailboxFolder.Read offline_access"
  "Mail.ReadBasic"
  "offline_access"
  "User.Read"
)

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

command -v az >/dev/null || { echo "Azure CLI (az) not found."; exit 1; }
az account show >/dev/null 2>&1 || { echo "Not signed in. Run: az login"; exit 1; }

TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Tenant: $TENANT_ID"

# Redirect URIs:
#   - nativeclient  : device code flow from the terminal
#   - msauth.<id>   : MSAL on iOS
#   - msauth.<id>.dev : the same, for local Debug builds (project.yml)
REDIRECT_URIS=(
  "https://login.microsoftonline.com/common/oauth2/nativeclient"
  "msauth.${IOS_BUNDLE_ID}://auth"
  "msauth.${IOS_BUNDLE_ID}.dev://auth"
)

EXISTING=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING" ]]; then
  echo "Reusing existing registration \"$APP_NAME\" ($EXISTING)."
  APP_ID="$EXISTING"
else
  echo "Creating app registration \"$APP_NAME\"..."
  APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience AzureADandPersonalMicrosoftAccount \
    --is-fallback-public-client true \
    --public-client-redirect-uris "${REDIRECT_URIS[@]}" \
    --query appId -o tsv)
fi

# Resolve each scope name to its GUID off the live Graph service principal,
# rather than hardcoding ids that can differ per cloud.
echo "Resolving Graph scope ids..."
GRAPH_SCOPES_JSON=$(az ad sp show --id "$GRAPH_APP_ID" --query "oauth2PermissionScopes" -o json)

RESOURCE_ACCESS=""
for scope in "${SCOPES[@]}"; do
  id=$(echo "$GRAPH_SCOPES_JSON" | jq -r --arg v "$scope" '.[] | select(.value == $v) | .id')
  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "  ! could not resolve scope $scope — skipping"
    continue
  fi
  echo "  $scope = $id"
  RESOURCE_ACCESS="${RESOURCE_ACCESS}{\"id\":\"$id\",\"type\":\"Scope\"},"
done

MANIFEST=$(mktemp -t rulebook-rra)
cat > "$MANIFEST" <<JSON
[{
  "resourceAppId": "$GRAPH_APP_ID",
  "resourceAccess": [${RESOURCE_ACCESS%,}]
}]
JSON

az ad app update --id "$APP_ID" --required-resource-accesses "@$MANIFEST"
rm -f "$MANIFEST"

# A service principal in this tenant is what makes the app consentable here.
az ad sp create --id "$APP_ID" >/dev/null 2>&1 || true

# The sign-in authority is NOT always the tenant the app was registered in.
# An app that accepts personal Microsoft accounts must authenticate against
# `common`; pinning the tenant GUID would shut those accounts out.
AUDIENCE=$(az ad app show --id "$APP_ID" --query signInAudience -o tsv)
case "$AUDIENCE" in
  AzureADandPersonalMicrosoftAccount) AUTHORITY="common" ;;
  AzureADMultipleOrgs)                AUTHORITY="organizations" ;;
  *)                                  AUTHORITY="$TENANT_ID" ;;
esac

cat <<SUMMARY

Done.

  Client ID     : $APP_ID
  Registered in : $TENANT_ID
  Audience      : $AUDIENCE
  Sign in via   : $AUTHORITY
  Scopes        : ${SCOPES[*]}

Add to your shell profile:

  export RULEBOOK_CLIENT_ID=$APP_ID
  export RULEBOOK_TENANT_ID=$AUTHORITY

Then:

  swift run rulebook login
  swift run rulebook list

MailboxSettings.ReadWrite is normally user-consentable, so the first sign-in
prompts you and nothing else is needed. If your tenant requires admin consent,
someone with the Cloud Application Administrator role runs:

  az ad app permission admin-consent --id $APP_ID

SUMMARY
