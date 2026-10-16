import std/[json, strutils, math]

proc reasoningEffortsFor*(catalog: JsonNode, backend, model, url: string): seq[string] =
  if catalog == nil or catalog.kind != JObject or
     not catalog.hasKey("inference_option_support") or
     catalog["inference_option_support"].kind != JArray:
    return @[]
  let base = url.strip().strip(leading = false, trailing = true, chars = {'/'})
  for row in catalog["inference_option_support"]:
    if row.kind != JObject: continue
    var matches = true
    for field in [("backend", backend), ("model", model)]:
      if not row.hasKey(field[0]) or row[field[0]].kind != JString or row[field[0]].getStr != field[1]:
        matches = false
    if not matches: continue
    if backend == "http" and (not row.hasKey("url") or row["url"].kind != JString or row["url"].getStr != base):
      continue
    if row.hasKey("reasoning_efforts") and row["reasoning_efforts"].kind == JArray:
      for choice in row["reasoning_efforts"]:
        if choice.kind == JString and choice.getStr in ["low", "medium", "high"]:
          result.add(choice.getStr)
    return

proc connectionOptionsPayload*(tokens, requests, wait, reasoning: string,
                               clearEmpty = false): JsonNode =
  ## Build only inference settings. Credentials and execution authority are
  ## deliberately outside this payload; the server validates ownership/limits.
  result = newJObject()
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
