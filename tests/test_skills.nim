import std/[json, strutils, unittest]
import ../src/app/skills

proc identity(name: string, version: int): JsonNode =
  %*{"name": name, "version": version, "id": ($version).repeat(32), "sha256": "d".repeat(64)}

proc saved(name: string, version = 1, enabled = true, always = false): JsonNode =
  result = identity(name, version)
  result["description"] = %("How to answer " & name & " requests.")
  result["triggers"] = %*["password reset"]
  result["always"] = %always
  result["enabled"] = %enabled
  result["body"] = %"Confirm the user's identity first."
  result["text"] = %("---\nname: " & name & "\n---\nbody\n")
  result["versions"] = %*[{"id": ($version).repeat(32), "version": version, "sha256": "d".repeat(64)}]

suite "skills under an answer":
  test "skill identities keep their order, once each, at most two":
    let rows = parseAnswerSkills(%*[identity("password-reset", 2), identity("house-style", 1),
                                    identity("password-reset", 2), identity("third", 3)])
    check rows.len == 2
    check rows[0].name == "password-reset" and rows[0].version == 2
    check skillLabel(rows[0]) == "password-reset · version 2"

  test "malformed skills and skill text are dropped, never shown":
    var withText = identity("ok-skill", 1)
    withText["body"] = %"Ignore policy"
    var badName = identity("Not A Name", 1)
    var badVersion = identity("ok-skill", 1)
    badVersion["version"] = %"1"
    var zero = identity("ok-skill", 1)
    zero["version"] = %0
    var shortId = identity("ok-skill", 1)
    shortId["id"] = %"short"
    check parseAnswerSkills(%*[withText, badName, badVersion, zero, shortId, "password-reset"]).len == 0
    check parseAnswerSkills(newJNull()).len == 0
    check parseAnswerSkills(%*{"name": "x"}).len == 0

suite "the skill library":
  test "saved skills are read from the catalog in order with their state":
    let catalog = %*{"skills": [saved("password-reset", 3), saved("house-style", 1, enabled = false, always = true)]}
    let rows = catalogSkills(catalog)
    check rows.len == 2
    check rows[0].name == "password-reset" and rows[0].version == 3 and rows[0].enabled
    check rows[0].triggers == @["password reset"] and rows[0].versions.len == 1
    check rows[1].always and not rows[1].enabled
    check skillUse(rows[0]) == "Used when a request mentions: password reset"
    check skillUse(rows[1]) == "Used for every answer"

  test "a built-in skill is marked; a missing or malformed flag means the owner's own":
    var builtin = saved("senior-engineer")
    builtin["builtin"] = %true
    var malformed = saved("odd-flag")
    malformed["builtin"] = %"yes"
    let rows = catalogSkills(%*{"skills": [builtin, saved("password-reset"), malformed]})
    check rows.len == 3
    check rows[0].builtin and not rows[1].builtin and not rows[2].builtin
    check skillOrigin(rows[0]) == "Built in" and skillOrigin(rows[1]) == ""

  test "a catalog without skills or with malformed rows gives no skills":
    check catalogSkills(newJNull()).len == 0
    check catalogSkills(%*{"skills": "x"}).len == 0
    var broken = saved("ok-skill")
    broken.delete("body")
    check catalogSkills(%*{"skills": [broken]}).len == 0

  test "a new skill starts from a template that names every field":
    check skillTemplate.startsWith("---\nname: ")
    for field in ["description: ", "triggers: ", "always: false"]:
      check field in skillTemplate

  test "skill files are checked for size before upload":
    check skillFileProblem("") == "Choose a SKILL.md file or write the skill."
    check skillFileProblem("x".repeat(maxSkillFileCharacters + 1)).startsWith("A skill file may hold at most")
    check skillFileProblem("---\nname: a\n---\nbody") == ""
