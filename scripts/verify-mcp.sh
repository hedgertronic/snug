#!/bin/bash
# verify-mcp.sh: the MCP server end to end, on a built .build/debug/Snug (run `swift build` first). The headless
# `--verify-agent-ui` check copies for an agent twice into a new temporary folder, so only the second bundle is left; JSON-RPC lines
# then go into `Snug --mcp -SnugAgentFolder FOLDER`, once with that bundle and once after it is removed.
# Prints each request and response (image data cut short) and exits non-zero when a response is not the expected one.
# Needs jq. Run it inside the debug lock, like any debug Snug run.
set -euo pipefail
cd "$(dirname "$0")/.."
snug=.build/debug/Snug
folder=$(mktemp -d "${TMPDIR:-/tmp}/snug-mcp.XXXXXX")
output=$("$snug" --verify-agent-ui "$folder" --image Tests/Fixtures/real-web/form-test.png)
grep "Agent UI verification passed" <<< "$output"
older=$(sed -n 's/^replaced capture: //p' <<< "$output")
newest=$(jq -rs '.[0].capture_id' "$folder"/*/manifest.json)
echo "folder $folder, bundle $newest (current) replaced $older"

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
zoom_older=$(printf '{"id":"%s","x":100,"y":10,"width":200,"height":40}' "$older")
zoom_outside=$(printf '{"id":"%s","x":500,"y":0,"width":200,"height":40}' "$newest")
replaced=".result.isError and .result.structuredContent.code == \"capture_replaced\" and .result.structuredContent.message == \"Capture $older was replaced by a newer capture. Ask the user to copy it again.\""
requests=(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify-mcp","version":"1"}}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    "$(call 3 get_capture '{"id":"latest"}')"
    "$(call 4 get_capture "$(printf '{"id":"%s"}' "$newest")")"
    "$(call 5 get_capture "$older_id")"
    "$(call 6 zoom "$zoom_older")"
    "$(call 7 zoom "$zoom")"
    "$(call 8 zoom "$zoom_outside")"
    "$(call 9 list_captures '{}')"
    "$(call 10 get_capture '{"id":"../x"}')"
)
# The notification gets no response, so it has no check.
checks=(
    '.id == 1 and .result.protocolVersion == "2025-06-18" and .result.serverInfo.name == "snug"'
    '[.result.tools[].name] == ["get_capture", "zoom"]'
    ".result.structuredContent.capture_id == \"$newest\" and .result.content[0].type == \"image\" and (.result.content[1].text | fromjson | .capture_id) == \"$newest\" and (.result.content[1].text | fromjson | has(\"expires_at\") | not)"
    ".result.structuredContent.capture_id == \"$newest\" and .result.isError == null"
    "$replaced"
    "$replaced"
    ".result.structuredContent == {\"capture_id\": \"$newest\", \"offset\": {\"x\": 100, \"y\": 10}, \"width\": 200, \"height\": 40}"
    '.result.isError and .result.structuredContent.code == "invalid_rect"'
    '.error.code == -32602'
    '.result.isError and .result.structuredContent.code == "capture_not_found"'
)
session

trash "$folder/$newest"
echo "removed $newest"
requests=("$(call 11 get_capture '{"id":"latest"}')" "$(call 12 get_capture "$older_id")")
checks=('.result.isError and .result.structuredContent.code == "capture_not_found"' '.result.isError and .result.structuredContent.code == "capture_not_found"')
session
echo "MCP verification passed"
