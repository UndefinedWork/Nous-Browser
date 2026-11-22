#!/bin/zsh
set -eu

# The pinned root is the self-signed publisher of v1.4.19. Developer ID
# certificates can renew within the same Apple team without pinning a leaf.
app="${1:?Expected a Nous Browser.app}"
previous="${2:-}"
team="$(/usr/libexec/PlistBuddy -c 'Print :NousStableStorageTeam' "${0:A:h:h}/Resources/Info.plist")"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Invalid release team identifier.'; exit 1; }
publisher="identifier \"com.cellier.nous-browser\" and ((anchor apple generic and certificate leaf[subject.OU] = \"$team\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or certificate root = H\"9133aa382a7c610414a0234dc917485db7a0eca7\")"

if ! /usr/bin/codesign --verify --strict -R="$publisher" "$app"; then
    print -u2 'The release app needs the Nous Developer ID Application identity or the original Nous Browser Local Signing certificate. An ad-hoc build cannot retain macOS privacy grants across updates.'
    exit 1
fi

if [[ -n "$previous" ]]; then
    previous_signature="$(/usr/bin/codesign -dvv "$previous" 2>&1)"
    /usr/bin/codesign --verify --strict "$previous"
    if ! print -r -- "$previous_signature" | /usr/bin/grep -qx 'Signature=adhoc'; then
        # macOS matches the requirement saved when the user granted access.
        # Test both directions, including after a certificate renewal.
        check_grant() {
            local requirement
            requirement="$(/usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
            [[ -n "$requirement" ]] && /usr/bin/codesign --verify --strict -R="$requirement" "$2"
        }
        if ! check_grant "$previous" "$app" || ! check_grant "$app" "$previous"; then
            print -u2 'The candidate and the previous stable app have incompatible macOS signing identities. Rebuild with the established release identity.'
            exit 1
        fi
    fi
fi
