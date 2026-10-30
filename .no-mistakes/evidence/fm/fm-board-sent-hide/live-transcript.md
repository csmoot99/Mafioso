# Live board drive: Send to Agent hides cards (headless Chromium 156, 390x844 phone viewport)
Board built by the real `bin/fm-bearings-board.sh build` with an 18-card Captain's Call payload (isolated FM_HOME, stubbed lavish-axi),
loaded in an iframe under a stand-in Lavish chrome page. The stand-in records the board's real `lavish.queuePrompt` calls
(text + CSS path of the form) and on Send to Agent posts `{type:"fm-board:send", phase, id, items}` to the board frame.

| Scenario | Observed |
|---|---|
| BASE c0792d2: answer 18, Send to Agent (start+sent) | 18 cards stay, "card 18 of 18 · 18 answered", need 18 (reported bug) |
| Answer 18, tap Send to Agent (start only) | 0 cards shown, need 0, "nothing needs you", "Nothing needs your action right now." |
| ...but card navigator | `hidden=true` yet computed display:flex, 44px tall, still reads "card 18 of 18 · 18 answered" with an enabled prev arrow (screenshot 03) |
| Same send then `failed` | all 18 back, need 18, "18 items wait on you" |
| Answer 5, wait for the next card to be dealt, send (start+sent) | Decision 6 shown, "card 1 of 13", need 13 |
| Answer 5, arrow back to answered Decision 3, send | jumps to Decision 8 ("card 3 of 13"); 6 and 7 stay reachable with prev |
| Same-shape message from the board's own window, and from a sibling frame, naming all 18 | ignored: card 1 of 18, need 18 |
| Parent: wrong type / unknown phase / numeric id / non-array items / text naming no card | ignored: need 18 |
| Parent `sent` with no prior `start`; selector names card 1 but text names Decision 7 | Decision 7 hidden, Decision 1 kept, 17 reachable via arrows |
| Overlapping sends A(1,2) and B(3): A fails, B sent | 16 -> 15 -> 17 -> 17; Decision 4 stays on screen |
