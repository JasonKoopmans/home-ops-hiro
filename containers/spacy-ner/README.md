# SpaCy NER Image

This directory contains the first-party image build context for the internal
`spacy-ner` API deployed in `kubernetes/apps/default/spacy-ner`.

## Build

```bash
docker build -t ghcr.io/jasonkoopmans/spacy-ner:0.1.0 containers/spacy-ner
```

## Push

```bash
docker push ghcr.io/jasonkoopmans/spacy-ner:0.1.0
```

## Local Run

```bash
docker run --rm -p 8080:8080 ghcr.io/jasonkoopmans/spacy-ner:0.1.0
```

Example request:

```bash
curl -sS -X POST http://localhost:8080/entities \
  -H 'Content-Type: application/json' \
  -d '{"text":"Google was founded in California in 1998."}'
```