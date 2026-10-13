import std/[asyncjs, jsfetch, jsheaders, json]
from std/httpcore import HttpGet, HttpPost
import ../config/runtime_config

proc extensionRequest*(action: string, payload: JsonNode, csrf: string): Future[JsonNode] {.async.} =
  let headers = newHeaders()
  headers["Content-Type"] = "application/json"
  headers["X-CSRF-Token"] = csrf
  let options = newFetchOptions(metod = HttpPost, credentials = fcInclude,
    mode = fmCors, headers = headers, body = cstring($(%*{"action": action, "payload": payload})))
  let response = await fetch((frontendConfig.backendBaseUrl & "/api/v1/extensions").cstring, options)
  let body = $(await response.text())
  if not response.ok:
    raise newException(ValueError, "Connection request failed (HTTP " & $response.status & "). Check access, input fields and server availability.")
  return parseJson(body)

proc extensionCatalog*(): Future[JsonNode] {.async.} =
  let response = await fetch((frontendConfig.backendBaseUrl & "/api/v1/extensions").cstring,
    newFetchOptions(metod = HttpGet, credentials = fcInclude, mode = fmCors))
  if not response.ok:
    raise newException(ValueError, "Connections could not be loaded.")
  return parseJson($(await response.text()))

proc datasetFileText*(): Future[cstring] {.importjs: "(async () => { const f=document.getElementById('datasetFile').files[0]; if(!f || f.size>2000000) throw new Error('Choose a text or JSONL file under 2 MB.'); return await f.text(); })()".}

proc uploadModelFiles*(baseUrl, csrf, name: cstring): Future[cstring] {.importjs: """
(async (base,csrf,name) => {
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
  return JSON.stringify(await call('upload_finish',{upload_id,name}));
})(#,#,#)
""".}

proc downloadTrainingDataset*(data: cstring) {.importjs: """
((data)=>{const parsed=JSON.parse(data);const blob=new Blob([parsed.records.map(r=>JSON.stringify(r)).join('\n')+'\n'],{type:'application/x-ndjson'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='reviewed-training-dataset.jsonl';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);})(#)
""".}
