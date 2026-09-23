## Naming

- **A name is given from the perspective of use, in the context it stands in**: what the thing is for
  where it is used, never how it was built. The reader pays for a name every time; the writer never
  does. [review]
- **A variable is a noun, a method is a verb, a boolean reads as a statement** (`isReady`,
  `hasKey`). A method that acts is an imperative; a method that answers reads as what it returns.
  One that promises both describes a method that does both, which is the defect. [review]
- **The standard verbs mean what they say:** `get` returns the thing or fails, `find` may return
  nothing, `list` returns many, `create`, `update` and `delete` do what they say. [review]
- **Length follows distance.** The further apart a name is declared and used, the longer it is.
  Extra words are a fault only when they repeat what the container already says. [review]
- **Things that form a family are named as one**, so a reader who has met two predicts the third.
  Where things differ along one axis, every one of them says which side it is on, or none does.
  [review]
- **A shared verb takes its object into the name.** Where a cluster, an image and a version can each
  be released, `release` names nothing. [review]
- **One concept, one word, everywhere**, in code, configuration, documents and messages to a person.
  A new name enters the project's glossary in the same change that introduces it, with its one
  meaning and the place it lives; a word with two spellings is listed there as contested until
  somebody decides it. The glossary is `docs/glossary.md` of the project harness, read in every
  checkout as `.ai-core/docs/<harness>/glossary.md`. [review]
- **A name is judged in the reader's context and re-judged wherever the thing moves.** A word that is
  exact inside a module can name nothing on a screen; a thing lifted into another context is
  renamed or confirmed there. [review]
- **A name is looked up before it is minted**, in the code, the configuration and the messages the
  tree already carries. Where a name exists, that name is the name. [review]
- **A configuration key and the nouns in an error message are names under these rules**, read by more
  people than any identifier, so they get full words. [review]
- **A name fixed by a standard outside the project is written as that standard spells it.** [review]
- **A reader judges a name, never a program.** Whether a name carries its meaning takes somebody who
  knows what the thing does and who uses it. [review]
