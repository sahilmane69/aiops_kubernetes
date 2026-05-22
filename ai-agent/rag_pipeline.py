"""RAG utilities for Kubernetes incident runbook retrieval."""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import List

import faiss
import numpy as np
from sentence_transformers import SentenceTransformer


DEFAULT_INDEX_PATH = Path(os.getenv("FAISS_INDEX_PATH", "/data/faiss-index"))
DEFAULT_RUNBOOKS_PATH = Path(os.getenv("RUNBOOKS_PATH", "/data/runbooks"))
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
CHUNK_SIZE_TOKENS = 500
CHUNK_OVERLAP_TOKENS = 50


@dataclass
class ChunkRecord:
    """Represents a single embedded runbook chunk."""

    source: str
    chunk_id: int
    content: str


class RunbookRAG:
    """Manages FAISS-backed retrieval over markdown runbooks."""

    def __init__(
        self,
        index_path: Path = DEFAULT_INDEX_PATH,
        runbooks_path: Path = DEFAULT_RUNBOOKS_PATH,
        model_name: str = MODEL_NAME,
    ) -> None:
        self.index_path = index_path
        self.runbooks_path = runbooks_path
        self.index_file = self.index_path / "index.faiss"
        self.metadata_file = self.index_path / "metadata.json"
        self.model = SentenceTransformer(model_name)

    def ingest(self) -> int:
        """Read markdown runbooks, chunk them, and persist embeddings in FAISS."""
        self.index_path.mkdir(parents=True, exist_ok=True)
        markdown_files = sorted(self.runbooks_path.glob("*.md"))
        records: List[ChunkRecord] = []

        for runbook in markdown_files:
            text = runbook.read_text(encoding="utf-8")
            chunks = self._chunk_text(text)
            for chunk_index, chunk in enumerate(chunks):
                records.append(
                    ChunkRecord(
                        source=runbook.name,
                        chunk_id=chunk_index,
                        content=chunk,
                    )
                )

        if not records:
            dimension = self.model.get_sentence_embedding_dimension()
            faiss.write_index(faiss.IndexFlatL2(dimension), str(self.index_file))
            self.metadata_file.write_text("[]", encoding="utf-8")
            return 0

        embeddings = self.model.encode(
            [record.content for record in records],
            show_progress_bar=False,
            normalize_embeddings=True,
        )
        vectors = np.asarray(embeddings, dtype=np.float32)
        index = faiss.IndexFlatIP(vectors.shape[1])
        index.add(vectors)
        faiss.write_index(index, str(self.index_file))
        self.metadata_file.write_text(
            json.dumps([record.__dict__ for record in records], indent=2),
            encoding="utf-8",
        )
        return len(records)

    def retrieve(self, query: str) -> str:
        """Return the top three most similar runbook chunks as a context block."""
        if not self.index_file.exists() or not self.metadata_file.exists():
            return "No indexed incidents or runbooks are available yet."

        metadata = json.loads(self.metadata_file.read_text(encoding="utf-8"))
        if not metadata:
            return "No indexed incidents or runbooks are available yet."

        index = faiss.read_index(str(self.index_file))
        query_vector = self.model.encode(
            [query], show_progress_bar=False, normalize_embeddings=True
        )
        distances, indices = index.search(np.asarray(query_vector, dtype=np.float32), 3)

        context_parts: List[str] = []
        for rank, (distance, idx) in enumerate(zip(distances[0], indices[0]), start=1):
            if idx < 0 or idx >= len(metadata):
                continue
            record = metadata[idx]
            score = max(0.0, min(1.0, float(distance)))
            context_parts.append(
                (
                    f"Match {rank} | source={record['source']} | chunk={record['chunk_id']} "
                    f"| similarity={score:.3f}\n{record['content']}"
                )
            )

        return "\n\n".join(context_parts) if context_parts else "No similar incidents found."

    def _chunk_text(self, text: str) -> List[str]:
        """Split text into token-like word chunks with overlap."""
        words = text.split()
        if not words:
            return []

        chunks: List[str] = []
        step = max(1, CHUNK_SIZE_TOKENS - CHUNK_OVERLAP_TOKENS)
        total_chunks = math.ceil(len(words) / step)

        for chunk_index in range(total_chunks):
            start = chunk_index * step
            end = start + CHUNK_SIZE_TOKENS
            chunk_words = words[start:end]
            if not chunk_words:
                continue
            chunks.append(" ".join(chunk_words))

        return chunks


_RAG_INSTANCE = RunbookRAG()


def ingest() -> int:
    """Convenience wrapper for indexing runbooks."""
    return _RAG_INSTANCE.ingest()


def retrieve(query: str) -> str:
    """Convenience wrapper for retrieval from the shared FAISS index."""
    return _RAG_INSTANCE.retrieve(query)
