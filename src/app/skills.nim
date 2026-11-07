## Owner skills (FR-090): reusable written guidance for the answers Janus writes.
##
## A skill is a SKILL.md file (YAML front matter, then the guidance). Skills are
## kept per owner by the AI service, which checks and versions them; they shape
## only how an answer is written, never which operation runs or its approval.
## An answer names the skill versions that guided it; their text is not shown there.

import std/[json, sets, strutils]

const
  maxAnswerSkills* = 2
  maxSkillFileCharacters* = 20_000
  skillTemplate* = "---\n" &
    "name: password-reset\n" &
    "description: How to answer password reset requests.\n" &
    "triggers: [password reset, locked out]\n" &
    "always: false\n" &
    "---\n" &
    "Confirm the user's identity before anything else.\n"

type
  AnswerSkill* = object
    name*, id*, sha256*: string
    version*: int

  SkillVersion* = object
    id*, sha256*: string
    version*: int

  SavedSkill* = object
    name*, description*, body*, text*, id*, sha256*: string
    triggers*: seq[string]
    always*, enabled*, builtin*: bool
    version*: int
    versions*: seq[SkillVersion]


proc text(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else: ""


proc hex(value: string, length: int): bool =
  value.len == length and value.allCharsInSet({'0'..'9', 'a'..'f'})


proc skillName(value: string): bool =
  value.len in 1..64 and value.allCharsInSet({'a'..'z', '0'..'9', '-'}) and
    value[0] != '-' and value[^1] != '-'


proc positive(node: JsonNode, key: string): int =
  if node != nil and node.kind == JObject and node.hasKey(key) and node[key].kind == JInt and
      node[key].getInt > 0:
    node[key].getInt
  else: 0


proc parseIdentity(node: JsonNode, row: var AnswerSkill): bool =
  if node == nil or node.kind != JObject or node.len != 4:
    return false
  row = AnswerSkill(name: text(node, "name"), id: text(node, "id"), sha256: text(node, "sha256"),
                    version: positive(node, "version"))
  skillName(row.name) and row.version > 0 and hex(row.id, 32) and hex(row.sha256, 64)


proc parseAnswerSkills*(node: JsonNode): seq[AnswerSkill] =
  ## Well-formed skill identities in order, once each, at most two; anything else is dropped.
  if node == nil or node.kind != JArray:
    return
  var seen = initHashSet[string]()
  for item in node:
    var row: AnswerSkill
    if result.len < maxAnswerSkills and parseIdentity(item, row) and row.id notin seen:
      seen.incl row.id
      result.add row


proc skillLabel*(row: AnswerSkill): string =
  row.name & " · version " & $row.version


proc flag(node: JsonNode, key: string): bool =
  node.hasKey(key) and node[key].kind == JBool and node[key].getBool


proc catalogSkills*(catalog: JsonNode): seq[SavedSkill] =
  ## The owner's saved skills from the extension catalog; malformed rows are left out.
  if catalog == nil or catalog.kind != JObject or not catalog.hasKey("skills") or
      catalog["skills"].kind != JArray:
    return
  for node in catalog["skills"]:
    var identity: AnswerSkill
    if node.kind != JObject or not parseIdentity(%*{"name": text(node, "name"), "id": text(node, "id"),
        "sha256": text(node, "sha256"), "version": positive(node, "version")}, identity):
      continue
    let body = text(node, "body")
    if body.len == 0 or text(node, "text").len == 0:
      continue
    var row = SavedSkill(name: identity.name, id: identity.id, sha256: identity.sha256,
      version: identity.version, description: text(node, "description"), body: body,
      text: text(node, "text"), always: flag(node, "always"), enabled: flag(node, "enabled"),
      builtin: flag(node, "builtin"))
    if node.hasKey("triggers") and node["triggers"].kind == JArray:
      for trigger in node["triggers"]:
        if trigger.kind == JString: row.triggers.add trigger.getStr
    if node.hasKey("versions") and node["versions"].kind == JArray:
      for version in node["versions"]:
        let number = positive(version, "version")
        if number > 0 and hex(text(version, "id"), 32):
          row.versions.add SkillVersion(id: text(version, "id"), sha256: text(version, "sha256"),
                                        version: number)
    result.add row


proc skillUse*(row: SavedSkill): string =
  ## When the skill guides an answer, in words.
  if row.always: "Used for every answer"
  elif row.triggers.len > 0: "Used when a request mentions: " & row.triggers.join(", ")
  else: "Used when a request names " & row.name


proc skillOrigin*(row: SavedSkill): string =
  ## "Built in" for a skill every owner starts with (still the owner's to edit, turn off or delete).
  if row.builtin: "Built in" else: ""


proc skillFileProblem*(content: string): string =
  ## Why a skill file cannot be sent, or "" when it can; the AI service checks the rest.
  if content.strip.len == 0: "Choose a SKILL.md file or write the skill."
  elif content.len > maxSkillFileCharacters:
    "A skill file may hold at most " & $maxSkillFileCharacters & " characters."
  else: ""
