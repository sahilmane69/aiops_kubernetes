"""CLI entrypoint for indexing markdown runbooks into FAISS."""

from __future__ import annotations

from rag_pipeline import ingest


def main() -> None:
    """Run FAISS ingestion and print the total indexed chunk count."""
    indexed_chunks = ingest()
    print(f"Indexed {indexed_chunks} runbook chunks.")


if __name__ == "__main__":
    main()
