# Round 2 live board drive at b2e81da (headless Chromium via playwright-core, 390x844 phone viewport)
The board was built by the real `bin/fm-bearings-board.sh build` from an 18-card Captain's Call payload (isolated FM_HOME, stubbed lavish-axi). It was loaded in an iframe under a stand-in Lavish chrome page, which records the board's real `lavish.queuePrompt(text, element)` calls and posts `{type:"fm-board:send", phase, id, items}` to the board frame when Send to Agent is tapped.
Each line reads the board's rendered state: visible cards, the navigator's `hidden` flag and *computed* display and height, the counters, and the empty note.

```
S0 loaded: {"shown":["Decision 1"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 1 of 18","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":true}
S1 answered 18, queued=18: {"shown":["Decision 18"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 18 of 18 · 18 answered","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":false}
S1 after Send to Agent (start): {"shown":[],"navHidden":true,"navDisplay":"none","navHeight":0,"navVisible":false,"count":"card 18 of 18 · 18 answered","need":"0","sub":"nothing needs you","emptyNote":"Nothing needs your action right now.","prevDisabled":false}
S1 after sent: {"shown":[],"navHidden":true,"navDisplay":"none","navHeight":0,"navVisible":false,"count":"card 18 of 18 · 18 answered","need":"0","sub":"nothing needs you","emptyNote":"Nothing needs your action right now.","prevDisabled":false}
S2 after failed: {"shown":["Decision 18"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 18 of 18 · 18 answered","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":false}
S2b re-send after failure: {"shown":[],"navHidden":true,"navDisplay":"none","navHeight":0,"navVisible":false,"count":"card 18 of 18 · 18 answered","need":"0","sub":"nothing needs you","emptyNote":"Nothing needs your action right now.","prevDisabled":false}
S3 partial 5 sent: {"shown":["Decision 6"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 1 of 13","need":"13","sub":"13 items wait on you","emptyNote":null,"prevDisabled":true}
S4 self-posted message: {"shown":["Decision 18"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 18 of 18 · 18 answered","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":false}
S4 note: previous line is a parent-posted message (control), see next for sibling
S4 after parent control: {"shown":[],"navHidden":true,"navDisplay":"none","navHeight":0,"navVisible":false,"count":"card 18 of 18 · 18 answered","need":"0","sub":"nothing needs you","emptyNote":"Nothing needs your action right now.","prevDisabled":false}
S4 sibling-frame message: {"shown":["Decision 18"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 18 of 18 · 18 answered","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":false}
S4 malformed parent messages: {"shown":["Decision 18"],"navHidden":false,"navDisplay":"flex","navHeight":44,"navVisible":true,"count":"card 18 of 18 · 18 answered","need":"18","sub":"18 items wait on you","emptyNote":null,"prevDisabled":false}
```
