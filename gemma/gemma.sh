#!/usr/bin/env bash
# Gemma Bash port: bash + curl + jq + openssl. OAuth client credentials via env.
set -o pipefail
API_KEY="$GEMINI_APIJ"; CID="$AGY_GOOGLE_CLIENT_ID"; CSECRET="$AGY_GOOGLE_CLIENT_SECRET"
PROVIDER="$GEMMA_PROVIDER"; MODEL="$GEMMA_MODEL"; SEARCH_MODEL="$GEMMA_SEARCH_MODEL"
[[ -n "$PROVIDER" ]] || PROVIDER=antigravity
[[ -n "$MODEL" ]] || MODEL=gemini-3.1-flash-lite
[[ -n "$SEARCH_MODEL" ]] || SEARCH_MODEL=gemini-3.1-flash-lite
GROUNDING=1; PERMISSION=ask; PROJECT=""
TOKEN="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
AGY=https://daily-cloudcode-pa.googleapis.com/v1internal
API=https://generativelanguage.googleapis.com/v1beta
for x in curl jq openssl; do command -v "$x" >/dev/null || { echo "Missing $x" >&2; exit 1; }; done
enc(){ jq -rn --arg x "$1" '$x|@uri'; }
b64u(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
refresh(){
 [[ -f "$TOKEN" ]] || { echo "Not signed in; use .auth login" >&2; return 1; }
 local exp now rt r
 exp="$(jq -r '.token.expiry // 0' "$TOKEN")"; now="$(date +%s)"
 (( exp > now+60 )) && return 0
 rt="$(jq -r '.token.refresh_token // empty' "$TOKEN")"
 [[ -n "$CID" && -n "$CSECRET" && -n "$rt" ]] || { echo "Set AGY_GOOGLE_CLIENT_ID/SECRET" >&2; return 1; }
 r="$(curl -fsS https://oauth2.googleapis.com/token -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "refresh_token=$rt" --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSECRET" --data-urlencode 'grant_type=refresh_token')" || return 1
 new_exp="$(date -u -d "@$((now+$(jq -r '.expires_in // 3600' <<<"$r")))" +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg a "$(jq -r .access_token <<<"$r")" --arg e "$new_exp" '.token.access_token=$a|.token.expiry=$e' "$TOKEN" > "$TOKEN.tmp" && mv "$TOKEN.tmp" "$TOKEN"
 chmod 600 "$TOKEN"
}
agy(){
 local method="$1" body="$2" t
 refresh || return 1; t="$(jq -r .token.access_token "$TOKEN")"
 curl -fsS "$AGY:$method" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' -H 'X-Goog-Api-Client: google-cloud-sdk vscode_cloudshelleditor/0.1' -H 'Client-Metadata: {"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}' --data "$body"
}
project(){
 [[ -n "$PROJECT" ]] && return 0
 local r; r="$(agy loadCodeAssist '{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}')" || return 1
 PROJECT="$(jq -r '.cloudaicompanionProject // empty' <<<"$r")"
 [[ -n "$PROJECT" ]]
}
login(){
 [[ -n "$CID" && -n "$CSECRET" ]] || { echo "Set AGY_GOOGLE_CLIENT_ID and AGY_GOOGLE_CLIENT_SECRET" >&2; return 1; }
 mkdir -p "$(dirname "$TOKEN")"
 local st vf ch scopes q url v code got r
 st="$(openssl rand -hex 32)"; vf="$(openssl rand -hex 48)"
 ch="$(printf %s "$vf"|openssl dgst -sha256 -binary|b64u)"
 scopes='https://www.googleapis.com/auth/aicode https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs openid'
 q="client_id=$(enc "$CID")&redirect_uri=$(enc https://antigravity.google/oauth-callback)&response_type=code&scope=$(enc "$scopes")&access_type=offline&prompt=consent&state=$st&code_challenge=$ch&code_challenge_method=S256"
 url="https://accounts.google.com/o/oauth2/v2/auth?$q"; echo "$url"
 if command -v xdg-open >/dev/null; then xdg-open "$url" >/dev/null 2>&1 & elif command -v open >/dev/null; then open "$url" >/dev/null 2>&1 & fi
 read -r -p 'Authorization code or callback URL: ' v
 if [[ "$v" == http* ]]; then
  code="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code",[""])[0])' "$v")"
  got="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("state",[""])[0])' "$v")"
  [[ -z "$got" || "$got" == "$st" ]] || { echo "OAuth state mismatch"; return 1; }
 else code="$v"; fi
 r="$(curl -fsS https://oauth2.googleapis.com/token -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "code=$code" --data-urlencode "client_id=$CID" --data-urlencode "client_secret=$CSECRET" --data-urlencode 'redirect_uri=https://antigravity.google/oauth-callback' --data-urlencode 'grant_type=authorization_code' --data-urlencode "code_verifier=$vf")" || return 1
 expiry="$(date -u -d "@$(($(date +%s)+$(jq -r '.expires_in // 3600' <<<"$r")))" +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg e "$expiry" '{auth_method:"consumer",token:{access_token:.access_token,refresh_token:.refresh_token,token_type:(.token_type//"Bearer"),expiry:$e}}' <<<"$r" > "$TOKEN"
 chmod 600 "$TOKEN"; echo "[OAuth saved] $TOKEN"
}
models(){
 if [[ "$PROVIDER" == antigravity ]]; then project || return 1; agy fetchAvailableModels "$(jq -n --arg p "$PROJECT" '{project:$p}')" | jq -r '.models // .modelInfos // .availableModels // [] | .[] | if type=="string" then . else (.catalogId//.modelId//.id//.name//"") end'
 else curl -fsS "$API/models?pageSize=100" -H "x-goog-api-key: $API_KEY" | jq -r '.models[]|select(.supportedGenerationMethods|index("generateContent"))|.name|sub("^models/";"")'; fi
}
request(){
 local p="$1" env
 if [[ "$PROVIDER" == antigravity ]]; then
  project || return 1
  env="$(jq -n --arg pr "$PROJECT" --arg m "$MODEL" --argjson r "$p" '{project:$pr,requestId:("agent-"+(now|tostring)),request:$r,model:$m,userAgent:"antigravity",requestType:"agent"}')"
  agy generateContent "$env"
 else curl -fsS "$API/models/$MODEL:generateContent?key=$API_KEY" -H 'Content-Type: application/json' --data "$p"; fi
}
search(){
 [[ "$GROUNDING" == 1 && "$PROVIDER" == antigravity ]] || { echo "$1"; return; }
 local p env r md notes
 project || { echo "$1"; return; }
 p="$(jq -n --argjson c "$1" '{systemInstruction:{role:"user",parts:[{text:"Research using Google Search. Return concise grounded notes."}]},contents:$c,tools:[{googleSearch:{}}],toolConfig:{includeServerSideToolInvocations:true}}')"
 env="$(jq -n --arg pr "$PROJECT" --arg m "$SEARCH_MODEL" --argjson r "$p" '{project:$pr,requestId:("search-"+(now|tostring)),request:$r,model:$m,userAgent:"antigravity",requestType:"agent"}')"
 r="$(agy generateContent "$env")" || { echo "$1"; return; }
 md="$(jq -c '.response.candidates[0].groundingMetadata // empty' <<<"$r")"
 [[ -n "$md" && "$md" != null ]] || { echo "[Search returned no grounding metadata]" >&2; echo "$1"; return; }
 notes="$(jq -r '[.response.candidates[0].content.parts[]?.text // empty]|join("\n")' <<<"$r")"
 notes+=$'\n'; notes+="$(jq -r '.response.candidates[0].groundingMetadata.groundingChunks[]?.web|select(.uri)|"- "+(.title//.uri)+" — "+.uri' <<<"$r")"
 jq --arg n "$notes" '. + [{role:"user",parts:[{text:("Search research (grounded):\n"+$n)}]}]' <<<"$1"
}
tool(){
 local n="$1" a="$2" cmd out rc
 case "$n" in
  get_current_datetime) jq -n --arg d "$(date --iso-8601=seconds)" '{datetime:$d}' ;;
  run_command)
   cmd="$(jq -r '.command//""' <<<"$a")"
   if [[ "$PERMISSION" == ask ]]; then read -r -p 'Allow command? [Y/n]: ' v; [[ -z "$v" || "$v" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo '{"denied":true}'; return; }; fi
   out="$(bash -lc "$cmd" 2>&1)"; rc=$?; jq -n --arg o "$out" --argjson c "$rc" '{exit_code:$c,output:$o}' ;;
  quick_web)
   case "$(jq -r '.action//""' <<<"$a")" in
    weather) curl -fsS "https://wttr.in/$(enc "$(jq -r '.query//""' <<<"$a")")?format=3" ;;
    public-ip) curl -fsS https://api.ipify.org ;;
    cheatsheet) curl -fsS "https://cht.sh/$(enc "$(jq -r '.query//""' <<<"$a")")" ;;
    *) echo '{"error":"unknown quick_web action"}' ;;
   esac ;;
  *) jq -n --arg n "$n" '{error:("unknown tool "+$n)}' ;;
 esac
}
ask(){
 local prompt="$1" mode="$2" c p r calls parts responses f n a tr
 c="$(jq -n --arg t "$prompt" '[{role:"user",parts:[{text:$t}]}]')"
 if [[ "$mode" != command && "$PROVIDER" == antigravity && "$GROUNDING" == 1 ]]; then c="$(search "$c")"; fi
 for ((i=0;i<32;i++)); do
  if [[ "$mode" == command ]]; then p="$(jq -n --arg t "$prompt" '{systemInstruction:{parts:[{text:"Return only a shell command. Do not execute it."}]},contents:[{role:"user",parts:[{text:$t}]}]}')"
  else p="$(jq -n --arg s 'You are Gemma. Be concise. Use run_command for local tasks.' --argjson c "$c" '{systemInstruction:{parts:[{text:$s}]},contents:$c,tools:[{functionDeclarations:[{name:"get_current_datetime",description:"Current local date/time",parameters:{type:"object",properties:{}}},{name:"run_command",description:"Run local shell command",parameters:{type:"object",properties:{command:{type:"string"}},required:["command"]}},{name:"quick_web",description:"Quick web lookup",parameters:{type:"object",properties:{action:{type:"string"},query:{type:"string"}},required:["action"]}}]}],toolConfig:{functionCallingConfig:{mode:"AUTO"}}}')"; fi
  r="$(request "$p")" || { echo "[API request failed]" >&2; return 1; }
  calls="$(jq -c '[.candidates[0].content.parts[]?.functionCall//empty]' <<<"$r")"
  if [[ "$mode" == command || "$calls" == '[]' || "$calls" == null ]]; then jq -r '[.candidates[0].content.parts[]?.text//empty]|join("\n")' <<<"$r"; return; fi
  parts="$(jq -c '.candidates[0].content.parts' <<<"$r")"; c="$(jq --argjson p "$parts" '.+[{role:"model",parts:$p}]' <<<"$c")"; responses='[]'
  while IFS= read -r f; do n="$(jq -r .name <<<"$f")"; a="$(jq -c '.args//{}' <<<"$f")"; tr="$(tool "$n" "$a")"; responses="$(jq --arg n "$n" --argjson r "$tr" '.+[{functionResponse:{name:$n,response:$r}}]' <<<"$responses")"; done < <(jq -c '.[]' <<<"$calls")
  c="$(jq --argjson p "$responses" '.+[{role:"user",parts:$p}]' <<<"$c")"
 done
 echo "Tool loop exceeded 32 rounds" >&2; return 1
}
help(){ echo ".q .model .provider antigravity|gemini .grounding on|off .ask .autopilot .auth login|status|logout"; echo "-p REQUEST | -e REQUEST"; }
main(){
 if [[ "$#" -gt 0 && "$1" == -p ]]; then shift; ask "$*" normal; return; fi
 if [[ "$#" -gt 0 && "$1" == -e ]]; then shift; ask "$*" command; return; fi
 help
 while true; do
  printf '\n> '; IFS= read -r line || break
  case "$line" in
   .q|.exit|.quit) break ;;
   .model) list="$(models)" || continue; i=1; while IFS= read -r m; do printf '%3d. %s\n' "$i" "$m"; ((i++)); done <<<"$list"; read -r -p 'Model number or ID: ' v; if [[ "$v" =~ ^[0-9]+$ ]]; then MODEL="$(sed -n "$v""p" <<<"$list")"; elif grep -Fxq "$v" <<<"$list"; then MODEL="$v"; fi; echo "[Model: $MODEL]" ;;
   .provider\ *) PROVIDER="$(cut -d' ' -f2- <<<"$line")"; echo "[Provider: $PROVIDER]" ;;
   '.grounding off') GROUNDING=0; echo '[Search OFF]' ;;
   '.grounding on') GROUNDING=1; echo '[Search ON]' ;;
   .ask) PERMISSION=ask; echo '[ASK]' ;;
   .autopilot) PERMISSION=autopilot; echo '[AUTOPILOT]' ;;
   '.auth login') login ;;
   '.auth status') [[ -f "$TOKEN" ]] && echo '[OAuth token exists]' || echo '[Not signed in]' ;;
   '.auth logout') rm -f "$TOKEN"; echo '[OAuth token removed]' ;;
   .clear) echo '[No retained history in initial Bash port]' ;;
   .save) echo '[Session save not implemented in initial Bash port]' ;;
   *) out="$(ask "$line" normal)" && printf '\n┌── GEMMA ──\n%s\n└──────────\n' "$out" ;;
  esac
 done
}
main "$@"
