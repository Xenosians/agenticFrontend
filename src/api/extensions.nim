import std/[asyncjs, jsfetch, jsheaders, json]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config
import http_call

proc extensionErrorMessage(
  body: string,
  status: string
): string =

  try:
    let parsed =
      decodeJson(body)

    if parsed.kind == JObject and
       parsed.hasKey("detail"):

      let detail =
        parsed["detail"]

      if detail.kind == JObject:

        var
          message = ""
          code = ""

        if detail.hasKey("message") and
           detail["message"].kind == JString:

          message =
            detail["message"].getStr

        if detail.hasKey("code") and
           detail["code"].kind == JString:

          code =
            detail["code"].getStr

        if message.len > 0:

          if code.len > 0:
            return (
              message &
              " (" &
              code &
              ")"
            )

          return message

      elif detail.kind == JString:

        let message =
          detail.getStr

        if message.len > 0:
          return message

  except CatchableError:
    discard

  return (
    "Connection request failed (HTTP " &
    status &
    "). Check access, input fields and " &
    "server availability."
  )


proc extensionRequest*(action: string, payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let options = newFetchOptions(metod = HttpPost, credentials = fcInclude,
    mode = fmCors, headers = headers, body = cstring($(%*{"action": action, "payload": payload})))
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/extensions", options)
  if not response.ok:
    raise newException(
      ValueError,
      extensionErrorMessage(
        response.body,
        $response.status
      )
    )
  return decodeJson(response.body)

proc extensionCatalog*(): Future[JsonNode] {.async.} =
  let response = await sendRequest(frontendConfig.backendBaseUrl & "/api/v1/extensions",
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok:
    raise newException(ValueError, "Connections could not be loaded.")
  return decodeJson(response.body)

proc datasetFileOutcome(): Future[cstring] {.importjs: """
(async () => {
  try {
    const f=document.getElementById('datasetFile').files[0];
    if(!f || f.size>2000000) throw new Error('Choose a text or JSONL file under 2 MB.');
    return JSON.stringify({value: await f.text()});
  } catch(error) {
    return JSON.stringify({error: error && typeof error.message==='string' ? error.message : 'The dataset file could not be read.'});
  }
})()
""".}

proc modelUploadOutcome(baseUrl, csrf, name: cstring): Future[cstring] {.importjs: """
(async (base,csrf,name) => {
 try {
  const files=Array.from(document.getElementById('modelFiles').files).filter(f=>/\.(json|safetensors|txt|model)$$/.test(f.name) && !f.name.startsWith('.'));
  if(!files.length) throw new Error('Choose a model folder first.');
  if(new Set(files.map(f=>f.name)).size!==files.length || files.some(f=>f.webkitRelativePath.split('/').length>2)) throw new Error('Choose one model folder without nested model data.');
  if(files.reduce((n,f)=>n+f.size,0)>20000000000) throw new Error('Model bundle exceeds 20 GB.');
  const call=async(action,payload)=>{
    const r=await fetch(base+'/api/v1/extensions',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({action,payload})});
    if(!r.ok) throw new Error('Model upload rejected (HTTP '+r.status+').');
    return await r.json();
  };
  const {upload_id}=await call('upload_begin',{});
  for(const file of files) {
    for(let offset=0;offset<file.size;offset+=1000000) {
      const bytes=new Uint8Array(await file.slice(offset,offset+1000000).arrayBuffer());
      let raw=''; for(let i=0;i<bytes.length;i+=8192) raw+=String.fromCharCode(...bytes.subarray(i,i+8192));
      await call('upload_chunk',{upload_id,filename:file.name,offset,base64:btoa(raw)});
    }
  }
  return JSON.stringify({value: JSON.stringify(await call('upload_finish',{upload_id,name}))});
 } catch(error) {
  return JSON.stringify({error: error && typeof error.message==='string' ? error.message : 'The model upload failed.'});
 }
})(#,#,#)
""".}

proc browserOutcome(raw: cstring): string =
  # Browser failures cross as data and become a normal Nim exception; a
  # native JavaScript Error would escape every CatchableError handler.
  let outcome = decodeJson($raw)
  if outcome.hasKey("error"):
    raise newException(ValueError, outcome["error"].getStr)
  outcome["value"].getStr

proc datasetFileText*(): Future[string] {.async.} =
  return browserOutcome(await datasetFileOutcome())

proc uploadModelFiles*(baseUrl, csrf, name: cstring): Future[string] {.async.} =
  return browserOutcome(await modelUploadOutcome(baseUrl, csrf, name))

proc downloadTrainingDataset*(data: cstring) {.importjs: """
((data)=>{const parsed=JSON.parse(data);const blob=new Blob([parsed.records.map(r=>JSON.stringify(r)).join('\n')+'\n'],{type:'application/x-ndjson'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='reviewed-training-dataset.jsonl';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);})(#)
""".}
