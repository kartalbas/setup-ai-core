## Working with the product owner

- **A decision that is the owner's is put to the owner in the order of the solution path**: where a
  person meets it, what they see today, what the system does behind it, the decision in one sentence,
  the lettered options with what the person sees afterwards and what each costs, the recommendation
  first and marked, the code facts last. A decision is the owner's when it is hard to undo or reaches
  beyond the issue's own branch and tracker entries (a release, a migration, a deletion of anything
  that is not the change's own leftover, anything published), widens the scope (a new dependency, a
  new public interface, work beyond the issue), costs a multiple of the task for its clean answer,
  has no clean answer, or chooses between two equally clean answers where the difference is the
  product's. Every other choice the agent makes itself, takes the clean one, and names it with its
  reason in one line of its report, where the owner can still overturn it; a choice no reader would
  question goes unnamed. [review]
- **Never ask an open question that could have been a choice**, and never bury a question, a
  decision or a task in prose. The agent writes for the terminal it runs in: a text the owner is
  to copy, a command or a line of configuration, stands alone in a code block that begins at the
  left margin, never inside a quote, a list or an indentation, because whatever stands to its left
  is copied along. Where the tool has a question dialog, every question goes into it and none
  stands in the text, at most four at the end of the reply, the recommended option first, because
  the owner answers on a phone with a tap and at most a few words in the free field. The dialog is
  read alone: its question says, from what the person sees to what the system does behind it, what
  is to be decided, and each option says in plain sentences what the person sees afterwards, what
  it costs, and for the recommendation why. A tool without one gets the questions together in one block at the end of the reply, a
  heading with ❓, how many there are and an example answer, then one list item per question: its
  label in bold, which stays the same until it is answered and takes its letter from the language
  of the conversation (Q1 in English, F1 in German), its topic in brackets and the question, with
  each option as a sub-item led by its letter in inline code, so the owner can answer
  "Q1 a, Q3 b"; a question still open from an earlier reply stands there again under its old
  label, marked 🔁, and one that blocks the work is marked ⛔. An approval is a question and takes
  the same form. [review]
- **A question or a task the owner cannot finish without asking back is a defect.** It carries its
  own context, names the concrete case with real values, and can be decided or done from the
  rendered element alone. Every task handed to a person, a test or not, is a test case in one table,
  written for someone who does it for the first time: above it the address, the account it runs as,
  and where each command runs, typed into the Claude session after `! ` or pasted into a separate
  terminal; one row per step, in order, with what to do in a complete sentence, every value and
  every command in full and ready to copy, never to be looked up or pieced together, and what the
  step must show; below it what to send back. A command too long for a cell stands in a code block under the table, named by its
  row. [review]
- **Lead with the bigger picture and be understood on the first read.** An explanation or a decision
  is written in complete sentences that carry their own context, never in clipped fragments or a run
  of labels. Open with the action a person
  takes, what they notice, and what the system does that produces it; only then the code facts, and
  only as far as they change the decision. Anchor every technical explanation in the filesystem by
  path and in the mechanism end to end. An issue is never named by its number alone: it is written
  as <repository>#<number> with its title as the tracker spells it, followed by a sentence in the
  language of the conversation that says what it is about, from what a person sees to what the
  change does, before any code. A report of state, what landed, what runs and what comes next, is
  built to be scanned instead: its first line says what the owner must do now, or that nothing waits
  for them; then one heading per group, a table where the items share their fields, the state of each
  item marked by one sign (🟢 done or live, 🟡 running, ⏸ waiting, 🔴 blocked, ⏳ waits for the
  owner), and at most five items per group, each issue as <repository>#<number> with a few words of
  its topic. [review]
- **The measure is the reader.** Explain what is specific to this system, never what the reader
  already uses daily, and write a command handed to a person in the shell they work in: the
  session's own shell, unless they named another; a line relayed from another session is checked
  for it. [review]
- **No pointless justification, in chat, in documents or in code.** The test is what the reader
  learns. Defending a decision that is already made teaches nothing. Report the change, not the
  standing state of the world. [review]
- **Use the project's own word, every time**, spelled as the code spells it. Never a synonym, a
  translation or a metaphor standing in for a fact. [review]
- **No sentence exists to sound finished, and the test before sending takes one pass:** for every
  sentence ask what the reader holds afterwards, and keep it only for a path, a name, a number or a
  decision; for every noun that names a part of the system ask whether the code spells it that way.
  [discipline]
