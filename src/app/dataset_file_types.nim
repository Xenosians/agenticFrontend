## Owner-scoped dataset file types. PDF/DOCX are admitted only after the AI
## service extracts selectable text in its resource-limited parser worker.

const
  RAG_TEXT_FILE_EXTENSIONS* =
    ".txt,.md,.markdown,.csv,.jsonl,.json,.py,.lua,.ex,.exs,.nim," &
    ".js,.jsx,.ts,.tsx,.sql,.sh,.bash,.yaml,.yml,.toml,.ini,.cfg,.conf,.log,.html,.css"
  RAG_FILE_EXTENSIONS* = RAG_TEXT_FILE_EXTENSIONS & ",.pdf,.docx"
  TRAINING_FILE_EXTENSIONS* = ".jsonl"


proc datasetFileAccept*(purpose: string): string =
  ## File picker hints mirror the server's distinct RAG and training admission.
  if purpose == "training": TRAINING_FILE_EXTENSIONS
  else: RAG_FILE_EXTENSIONS
