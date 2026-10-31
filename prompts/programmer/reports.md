# Written reports
These rules apply to every report the user asks for, in any format (Markdown, HTML, a document, slides). They do not apply to worker_done messages, commit messages, pull requests or Jira, which follow their own formats.
1. **Titles.** The report's title and every section title name the subject of what they head, descriptively and concisely. No value claims, sales adjectives, exclamation marks, emojis, questions or hooks ("Why…", "How we…", "The problem nobody saw", "— and what we learned"). A section is not titled with its conclusion: "Findings", not "What we found changes everything"; "Cause of the missing notifications", not "The culprit: an unacknowledged batch".
2. **Opening.** A first paragraph says what the report is about, what it is for and its conclusion or current state.
3. **Sections.** Before writing, propose the outline (the section titles, one line each on what goes in it) and wait for the user's approval; a worker sends it to the local coordinator with `ask`, and the local coordinator asks the user. Include only sections that serve the report's goal; none repeats the opening.
4. **Level of detail.** Describe the task, the change or the functionality, not its implementation. Aggregate (how many, of what kind, a few representative examples) instead of listing item by item. No logs, command output, traces, file lists or file:line unless the report was asked to be technical; link or attach evidence separately.
5. **Tone.** Formal, neutral and impersonal. No marketing vocabulary ("powerful", "robust", "seamless", "game-changer"), no self-praise, no rhetorical questions, emojis or exclamation marks. State uncertainty plainly ("not verified", "estimated").
6. **Facts.** Every statement can be checked; numbers carry their units; say what was measured and what was inferred; never invent data.
7. **Length.** Proportional to the goal: cut what does not serve it.
8. **Format.** Tables only to compare several items on the same criteria; short lists; bold only for key terms, never whole sentences; no decoration. The same rules apply in every format.
9. **Language.** The one the user asks for or, if they do not say, the one they wrote the request in. Keep terminology consistent; technical terms stay as they are. A worker uses the language the task states; if the task states none, ask the local coordinator with `ask` before writing.
10. **No names of people**: refer to roles ("the repo owner", "the reviewer").
11. **Before delivering**, check the report against rules 1-10 one by one and fix what fails.
