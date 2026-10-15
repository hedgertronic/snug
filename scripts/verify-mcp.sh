#!/bin/bash
# verify-mcp.sh: the MCP server end to end, on a built .build/debug/Snug (run `swift build` first). The headless
# `--verify-agent-ui` check writes two agent bundles into a new temporary folder; JSON-RPC lines then go into
# `Snug --mcp -SnugAgentFolder FOLDER`, once as written and once after the older bundle's expiry is moved into the past.
# Prints each request and response (image data cut short) and exits non-zero when a response is not the expected one.
# Needs jq. Run it inside the debug lock, like any debug Snug run.
set -euo pipefail
cd "$(dirname "$0")/.."
snug=.build/debug/Snug
folder=$(mktemp -d "${TMPDIR:-/tmp}/snug-mcp.XXXXXX")
"$snug" --verify-agent-ui "$folder" --image notes/real-web/form-test.png | grep "Agent UI verification passed"
older=$(jq -rs 'sort_by(.captured_at) | .[0].capture_id' "$folder"/*/manifest.json)
newest=$(jq -rs 'sort_by(.captured_at) | .[-1].capture_id' "$folder"/*/manifest.json)
echo "folder $folder, bundles $older (older) and $newest (newest)"

# One server session: sends the lines in `requests`, then checks the Nth response against the Nth jq filter in `checks`.
session() {
    printf '>> %s\n' "${requests[@]}"
    local responses index=0
    responses=$(printf '%s\n' "${requests[@]}" | "$snug" --mcp -SnugAgentFolder "$folder")
    while IFS= read -r response; do
        echo "<< $(jq -c 'walk(if type == "object" and has("data") then .data = (.data[0:16] + "... (\(.data | length) base64 chars)") else . end)' <<< "$response")"
        jq -e "${checks[$index]}" <<< "$response" > /dev/null || { echo "FAILED: ${checks[$index]}"; exit 1; }
        index=$((index + 1))
    done <<< "$responses"
    [ "$index" -eq "${#checks[@]}" ] || { echo "FAILED: $index responses for ${#checks[@]} checks"; exit 1; }
}

call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
# Arguments with commas are built here: bash 3.2 brace-expands them inside a quoted command substitution.
older_id=$(printf '{"id":"%s"}' "$older")
zoom=$(printf '{"id":"%s","x":100,"y":10,"width":200,"height":40}' "$newest")
zoom_outside=$(printf '{"id":"%s","x":500,"y":0,"width":200,"height":40}' "$newest")
requests=(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify-mcp","version":"1"}}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    "$(call 3 get_capture '{"id":"latest"}')"
    "$(call 4 get_capture "$older_id")"
    "$(call 5 zoom "$zoom")"
    "$(call 6 zoom "$zoom_outside")"
    "$(call 7 list_captures '{}')"
    "$(call 8 get_capture '{"id":"ZZZZZZZZ"}')"
)
# The notification gets no response, so it has no check.
checks=(
    '.id == 1 and .result.protocolVersion == "2025-06-18" and .result.serverInfo.name == "snug"'
    '[.result.tools[].name] == ["get_capture", "zoom", "list_captures"]'
    ".result.structuredContent.capture_id == \"$newest\" and .result.content[0].type == \"image\" and (.result.content[1].text | fromjson | .capture_id) == \"$newest\""
    ".result.structuredContent.capture_id == \"$older\" and .result.isError == null"
    ".result.structuredContent == {\"capture_id\": \"$newest\", \"offset\": {\"x\": 100, \"y\": 10}, \"width\": 200, \"height\": 40}"
    '.result.isError and .result.structuredContent.code == "invalid_rect"'
    "[.result.structuredContent.captures[].id] == [\"$newest\", \"$older\"]"
    '.result.isError and .result.structuredContent.code == "capture_not_found"'
)
session

manifest="$folder/$older/manifest.json"
jq '.expires_at = "2026-01-01T00:00:00.000Z"' "$manifest" > "$manifest.new"
mv "$manifest.new" "$manifest"
echo "moved $older's expiry to 2026-01-01"
requests=("$(call 9 get_capture "$older_id")" "$(call 10 list_captures '{}')")
checks=('.result.isError and .result.structuredContent.code == "capture_expired"' "[.result.structuredContent.captures[].id] == [\"$newest\"]")
session
echo "MCP verification passed"
