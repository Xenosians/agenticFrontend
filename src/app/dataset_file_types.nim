## Plain-text source types offered by the existing owner-scoped dataset upload.
## Binary document formats require a separate server-side parser/admission flow.

const
  RAG_FILE_EXTENSIONS* =
    ".txt,.md,.markdown,.csv,.jsonl,.json,.py,.lua,.ex,.exs,.nim," &
    ".js,.jsx,.ts,.tsx,.sql,.sh,.bash,.yaml,.yml,.toml,.ini,.cfg,.conf,.log,.html,.css"
  TRAINING_FILE_EXTENSIONS* = ".jsonl"


proc datasetFileAccept*(purpose: string): string =
  ## File picker hints mirror the server's distinct RAG and training admission.
  if purpose == "training": TRAINING_FILE_EXTENSIONS
  else: RAG_FILE_EXTENSIONS
