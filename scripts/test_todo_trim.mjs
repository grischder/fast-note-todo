// Regression test for the completed-history trimming, mirroring the logic in
// Panel.qml's saveTodosNow() / finishTodoSave().
//
// The bug this guards: the save used to remember only *how many* entries to
// drop and then dropped that many from the tail of the current list. If an
// entry was restored while the save was in flight, the count pointed at a
// different entry and that one disappeared instead.
//
// Run with: node scripts/test_todo_trim.mjs

let failures = 0
let passes = 0

function check(name, expected, actual) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log(`PASS  ${name}`)
    passes++
  } else {
    console.log(`FAIL  ${name}\n      expected=${e}\n      actual=${a}`)
    failures++
  }
}

// completedItems is newest-first, exactly as in the plugin
const A = { text: "newest", completedAt: 300 }
const B = { text: "middle", completedAt: 200 }
const C = { text: "oldest", completedAt: 100 }

function trimToFit(items, maxItems) {
  // saveTodosNow(): drop from the tail until the payload fits
  const trimmed = items.slice(0, maxItems)
  const dropped = items.slice(trimmed.length)
  return { trimmed, dropped }
}

function finishSave(currentItems, droppedEntries) {
  // finishTodoSave(): drop only the entries that were selected for trimming
  // and are still present
  return currentItems.filter((entry) =>
    !droppedEntries.some(
      (d) => d.text === entry.text && d.completedAt === entry.completedAt
    )
  )
}

// 1. plain trim: the oldest entry is selected and removed
{
  const { dropped } = trimToFit([A, B, C], 2)
  const after = finishSave([A, B, C], dropped)
  check("trim removes only the oldest entry", [A, B], after)
}

// 2. restore during the save: the selected entry is restored (removed from
//    history) before the save finishes; the remaining entry must survive
{
  const { dropped } = trimToFit([A, B, C], 2) // C selected for trimming
  const duringSave = [A, B] // C restored by the user meanwhile
  const after = finishSave(duringSave, dropped)
  check("restoring a trimmed entry does not drop another one", [A, B], after)
}

// 3. a new completed entry added during the save is kept
{
  const D = { text: "just finished", completedAt: 400 }
  const { dropped } = trimToFit([A, B, C], 2)
  const duringSave = [D, A, B] // C trimmed away earlier, D completed meanwhile
  const after = finishSave(duringSave, dropped)
  check("an entry completed during the save is kept", [D, A, B], after)
}

// 4. nothing to trim: the list is untouched
{
  const { dropped } = trimToFit([A, B, C], 3)
  const after = finishSave([A, B, C], dropped)
  check("no trimming leaves the list unchanged", [A, B, C], after)
}

// 5. restoring the *newest* entry while two are trimmed
{
  const { dropped } = trimToFit([A, B, C], 1) // B and C selected
  const duringSave = [A, C] // B restored, C still selected
  const after = finishSave(duringSave, dropped)
  check("only the still-selected entry is dropped", [A], after)
}

console.log(`\npassed=${passes} failed=${failures}`)
process.exit(failures === 0 ? 0 : 1)
