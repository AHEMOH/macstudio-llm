# RAG pipeline on the Mac Studio LLM server

> Design/reference notes for a future project: turn your documents into a
> "chat with your documents" system, reusing services this server already runs.
> Nothing here is installed by `setup.sh` yet — it's the recipe + exact API calls.

## Architecture

```
PDFs/images ──▶ docling  ──▶ chunks ──▶ embed (bge-m3) ──▶ Qdrant
 (:5001 hybrid chunker)      (aligned      (:11434            (vector DB)
                              to bge-m3)    /v1/embeddings)        │
                                                                   ▼
 OpenWebUI ◀── OpenAI /v1 ◀── Haystack ◀── rerank (bge-reranker) ◀ top-k
   (chat)      (RAG server)   (retrieve →   (:11434 /v1/rerank)
                               rerank →
                               call `main`)
```

Everything except Qdrant + the Haystack glue already runs here:
- **docling-serve** — on-demand at `:5001` (proxy). Converts + chunks in one call.
- **`embed`** / **`rerank`** — LiteLLM aliases at `:11434` (Infinity, BAAI/bge-m3 +
  bge-reranker-v2-m3). See [INTEGRATIONS.md](../INTEGRATIONS.md).
- **`main`** / **`main-fast`** — the generation model at `:11434`.

Key idea: **align the chunker's tokenizer to the embedder.** bge-m3's tokenizer is used by
the HybridChunker so chunk sizes match what bge-m3 actually embeds (≤ 8192 tokens; use ~512
for retrieval granularity).

## 1. Convert + chunk (docling)

docling produces `DoclingDocument` then chunks it — OCR-engine-agnostic. For scanned docs
use `ocrmac`; for born-digital PDFs OCR is skipped automatically.

```sh
curl -s http://mac.home.arpa:5001/v1/chunk/hybrid/file \
  -F "files=@invoice.pdf;type=application/pdf" \
  -F "convert_ocr_engine=ocrmac" \
  -F "convert_force_ocr=false" \
  -F "image_export_mode=placeholder" \
  -F "chunking_tokenizer=BAAI/bge-m3" \
  -F "chunking_max_tokens=512" \
  -F "chunking_merge_peers=true" | tee chunks.json | python3 -c '
import sys,json; d=json.load(sys.stdin)
print("chunks:", len(d.get("chunks", d.get("documents", []))))'
```

Each chunk carries the text plus provenance (source doc, page). Keep that as payload for
citations. (Note: this is the same docling server the paperless Apple-OCR service does NOT
use — that path is OCRmyPDF-style searchable PDFs; docling here is purely for RAG text.)

## 2. Embed the chunks (bge-m3, 1024-dim)

```sh
curl -s http://mac.home.arpa:11434/v1/embeddings \
  -H 'Authorization: Bearer sk-local' -H 'Content-Type: application/json' \
  -d '{"model":"embed","input":["chunk text 1","chunk text 2"]}' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["data"]),"vectors, dim",len(d["data"][0]["embedding"]))'
```

Batch chunks (Infinity batches internally). Output is 1024-dim dense vectors.

## 3. Store in Qdrant

Run Qdrant (Docker, on the Mac or any host). Create a collection matching bge-m3:

```python
from qdrant_client import QdrantClient, models
qc = QdrantClient(url="http://qdrant.home.arpa:6333")
qc.recreate_collection(
    "docs",
    vectors_config=models.VectorParams(size=1024, distance=models.Distance.COSINE),
)
# upsert: id, vector (from step 2), payload {"text":..., "source":..., "page":...}
```

## 4. Retrieve + rerank

Embed the **query** (step 2), pull top-N (e.g. 30) from Qdrant, then rerank with the
cross-encoder for precision, keep top-K (e.g. 6):

```sh
curl -s http://mac.home.arpa:11434/v1/rerank \
  -H 'Authorization: Bearer sk-local' -H 'Content-Type: application/json' \
  -d '{"model":"rerank","query":"Wie hoch ist die Miete?","documents":["...","..."],"top_n":6}'
```

## 5. Serve to OpenWebUI

Wrap steps 2–4 + generation in a small **Haystack** (or LlamaIndex/custom) app that exposes
an **OpenAI-compatible** `/v1/chat/completions`: it embeds the user's last message,
retrieves + reranks from Qdrant, stuffs the top-K chunks into a system/context prompt, and
calls `main` (or `main-fast`) at `:11434`. Then in **OpenWebUI → Settings → Connections**
add that app as an OpenAI endpoint and chat against your documents (with citations from the
chunk payloads).

Tips:
- Keep `chunking_max_tokens` × K well under `main`'s context; ~512×6 ≈ 3K tokens leaves room.
- `main-fast` (thinking-off) is usually the right generation model for RAG answers.
- Reuse the same bge-m3 for query + document embeddings (already guaranteed here).
