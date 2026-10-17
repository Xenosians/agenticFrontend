import std/[json, strutils, math]

type NetworkingInferenceChoice* = tuple[id, label: string]

proc networkingInferenceChoices*(catalog: JsonNode): seq[NetworkingInferenceChoice] =
  if catalog == nil or catalog.kind != JObject or
     not catalog.hasKey("networking_inference_options"):
    return
  let support = catalog["networking_inference_options"]
  if support.kind != JObject or not support.hasKey("choices") or support["choices"].kind != JArray:
    return
  for choice in support["choices"]:
    if choice.kind != JObject or not choice.hasKey("id") or not choice.hasKey("label") or
       choice["id"].kind != JString or choice["label"].kind != JString:
      continue
    let identity = choice["id"].getStr
    if identity notin ["dedicated_local", "selected_model"] or choice["label"].getStr.len == 0:
      continue
    var duplicate = false
    for existing in result:
      if existing.id == identity: duplicate = true
    if not duplicate: result.add((identity, choice["label"].getStr))

proc networkingInferenceDefault*(catalog: JsonNode): string =
  result = "dedicated_local"
  if catalog != nil and catalog.kind == JObject and catalog.hasKey("networking_inference_options"):
    let support = catalog["networking_inference_options"]
    if support.kind == JObject and support.hasKey("default") and support["default"].kind == JString:
      for choice in networkingInferenceChoices(catalog):
        if support["default"].getStr == choice.id: return choice.id

proc optionText*(item: JsonNode, key: string): string =
  if item != nil and item.kind == JObject and item.hasKey(key):
    case item[key].kind
    of JString: return item[key].getStr
    of JInt, JFloat: return $item[key]
    else: discard
  return ""

proc optionRowFor(catalog: JsonNode, backend, model, url: string): JsonNode =
  ## The server's capability row for this connection. A row without a model
  ## applies to every model served by that backend/url.
  if catalog == nil or catalog.kind != JObject or
     not catalog.hasKey("inference_option_support") or
     catalog["inference_option_support"].kind != JArray:
    return nil
  let base = url.strip().strip(leading = false, trailing = true, chars = {'/'})
  for row in catalog["inference_option_support"]:
    if row.kind != JObject: continue
    if not row.hasKey("backend") or row["backend"].kind != JString or row["backend"].getStr != backend:
      continue
    if row.hasKey("model") and (row["model"].kind != JString or row["model"].getStr != model):
      continue
    if backend == "http" and (not row.hasKey("url") or row["url"].kind != JString or row["url"].getStr != base):
      continue
    return row
  return nil

proc allowedChoices(row: JsonNode, key: string, allowed: openArray[string]): seq[string] =
  if row == nil or not row.hasKey(key) or row[key].kind != JArray:
    return
  for choice in row[key]:
    if choice.kind == JString and choice.getStr in allowed and choice.getStr notin result:
      result.add(choice.getStr)

proc reasoningEffortsFor*(catalog: JsonNode, backend, model, url: string): seq[string] =
  allowedChoices(optionRowFor(catalog, backend, model, url), "reasoning_efforts", ["low", "medium", "high"])

proc thinkingModesFor*(catalog: JsonNode, backend, model, url: string): seq[string] =
  allowedChoices(optionRowFor(catalog, backend, model, url), "thinking_modes", ["adaptive", "disabled"])

proc connectionOptionsPayload*(tokens, requests, wait, reasoning: string,
                               clearEmpty = false, networking = "", backend = "http",
                               thinking = ""): JsonNode =
  ## Build only inference settings. Credentials and execution authority are
  ## deliberately outside this payload; the server validates ownership/limits.
  result = newJObject()
  if networking.len > 0:
    if networking notin ["dedicated_local", "selected_model"]:
      raise newException(ValueError, "Choose an available networking model option.")
    result["networking_inference"] = %networking
  if backend in ["local", "uploaded"]:
    return
  if backend notin ["http", "pi", "opencode"]:
    raise newException(ValueError, "Choose an available connection type.")
  for item in [("provider_tokens_per_minute", tokens, 1_000_000_000),
               ("provider_requests_per_minute", requests, 1_000_000)]:
    let text = item[1].strip()
    if text.len == 0:
      if clearEmpty: result[item[0]] = newJNull()
    else:
      let value = parseInt(text)
      if value < 1 or value > item[2]:
        raise newException(ValueError, "Enter a positive provider usage limit within the supported range.")
      result[item[0]] = %value
  let waitText = wait.strip()
  if waitText.len == 0:
    if clearEmpty: result["admission_max_wait_seconds"] = newJNull()
  else:
    let value = parseFloat(waitText)
    if classify(value) in {fcNan, fcInf, fcNegInf} or value < 0 or value > 120:
      raise newException(ValueError, "Queue wait must be between 0 and 120 seconds.")
    result["admission_max_wait_seconds"] = %value
  let effort = reasoning.strip()
  if effort.len == 0:
    if clearEmpty: result["reasoning_effort"] = newJNull()
  elif effort in ["low", "medium", "high"]:
    result["reasoning_effort"] = %effort
  else:
    raise newException(ValueError, "Choose an available reasoning effort.")
  let mode = thinking.strip()
  if mode.len == 0:
    if clearEmpty: result["thinking_mode"] = newJNull()
  elif mode in ["adaptive", "disabled"]:
    result["thinking_mode"] = %mode
  else:
    raise newException(ValueError, "Choose an available thinking mode.")
