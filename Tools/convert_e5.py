#!/usr/bin/env python3
"""Conversion de intfloat/multilingual-e5-small vers CoreML pour FouineEmbed.

Produit dans le répertoire cible (défaut :
~/Library/Application Support/Fouine/models/e5-small) :
  E5Small.mlmodelc/   modèle compilé (entrées input_ids/attention_mask [1,256] i32,
                      sortie hidden [1,256,384] — mean pooling fait côté Swift)
  vocab.json          vocabulaire Unigram [[pièce, log-prob], …] indexé par id
  meta.json           dimensions, longueur de séquence, préfixes e5, révision
  parity.json         vecteurs de test : chaînes -> ids HF + embeddings de référence
                      (valident le tokenizer Swift ET le pipeline complet)

Usage : venv/bin/python Tools/convert_e5.py [dossier_cible]
Licence du modèle : MIT (intfloat/multilingual-e5-small).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

MODEL = "intfloat/multilingual-e5-small"
SEQ = 256
REVISION = 1

out_dir = os.path.expanduser(
    sys.argv[1] if len(sys.argv) > 1
    else "~/Library/Application Support/Fouine/models/e5-small")
os.makedirs(out_dir, exist_ok=True)

print("== chargement", MODEL, flush=True)
tok = AutoTokenizer.from_pretrained(MODEL)
model = AutoModel.from_pretrained(MODEL)
model.eval()


class Wrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_ids, attention_mask):
        return self.m(input_ids=input_ids,
                      attention_mask=attention_mask).last_hidden_state


print("== trace TorchScript", flush=True)
ex_ids = torch.zeros((1, SEQ), dtype=torch.int32)
ex_mask = torch.zeros((1, SEQ), dtype=torch.int32)
ex_ids[0, 0], ex_ids[0, 1] = 0, 2      # <s> </s>
ex_mask[0, :2] = 1
with torch.no_grad():
    traced = torch.jit.trace(Wrapper(model), (ex_ids, ex_mask))

print("== conversion CoreML (mlprogram fp16)", flush=True)
import coremltools as ct  # import tardif : message d'erreur plus clair si absent

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ), dtype=np.int32)],
    outputs=[ct.TensorType(name="hidden")],
    minimum_deployment_target=ct.target.macOS13,
    convert_to="mlprogram",
)
with tempfile.TemporaryDirectory() as tmp:
    pkg = os.path.join(tmp, "E5Small.mlpackage")
    mlmodel.save(pkg)
    print("== compilation coremlcompiler", flush=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, tmp], check=True)
    dst = os.path.join(out_dir, "E5Small.mlmodelc")
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.move(os.path.join(tmp, "E5Small.mlmodelc"), dst)

print("== export vocabulaire", flush=True)
with tempfile.TemporaryDirectory() as tmp:
    tok.save_pretrained(tmp)
    tj = json.load(open(os.path.join(tmp, "tokenizer.json")))
vocab = tj["model"]["vocab"]           # [[pièce, log-prob], …], indexé par id
unk_id = tj["model"]["unk_id"]
json.dump({"vocab": vocab, "unk_id": unk_id},
          open(os.path.join(out_dir, "vocab.json"), "w"), ensure_ascii=False)

json.dump({
    "model_id": "multilingual-e5-small",
    "revision": REVISION,
    "dim": int(model.config.hidden_size),
    "seq": SEQ,
    "bos_id": 0, "eos_id": 2, "pad_id": 1,
    "prefix_query": "query: ",
    "prefix_passage": "passage: ",
    "normalizer": tj.get("normalizer", {}).get("type", ""),
    "pre_tokenizer": json.dumps(tj.get("pre_tokenizer", {})),
}, open(os.path.join(out_dir, "meta.json"), "w"))

print("== vecteurs de parité", flush=True)
samples = [
    "query: la sélectivité des catalyseurs",
    "passage: Gibbs free energy and reaction enthalpy",
    "passage: L'énergie libre de Gibbs gouverne la spontanéité des "
    "transformations chimiques à température et pression constantes.",
    "passage: régiosélectivité de l'hydroboration des alcènes",
    "passage: Phase transitions in polymer melts: crystallization kinetics",
    "passage: pKa = 4,76 (acide acétique) ; ΔG° = -RT ln K",
    "query: chromatographie",
    "passage: Ψ(x,t) — l'équation de Schrödinger dépendante du temps",
    "passage:   espaces   multiples\tet tabulations\nretours à la ligne  ",
    "passage: MixedCase WORDS and français Œuvre cœur naïve",
]


def reference_embedding(text):
    enc = tok(text, max_length=SEQ, truncation=True, return_tensors="pt")
    with torch.no_grad():
        h = model(**enc).last_hidden_state[0]          # [n, dim]
    mask = enc["attention_mask"][0].unsqueeze(-1)
    v = (h * mask).sum(0) / mask.sum()
    v = v / v.norm()
    return v.tolist()


parity = []
for s in samples:
    ids = tok(s, max_length=SEQ, truncation=True)["input_ids"]
    parity.append({"text": s, "ids": ids})
# Embeddings de référence pour 4 chaînes (validation du pipeline complet).
refs = [{"text": s, "embedding": reference_embedding(s)} for s in samples[:4]]
json.dump({"tokens": parity, "embeddings": refs},
          open(os.path.join(out_dir, "parity.json"), "w"), ensure_ascii=False)

print("== terminé ->", out_dir, flush=True)
for f in sorted(os.listdir(out_dir)):
    p = os.path.join(out_dir, f)
    size = sum(os.path.getsize(os.path.join(dp, fn))
               for dp, _, fns in os.walk(p) for fn in fns) \
        if os.path.isdir(p) else os.path.getsize(p)
    print(f"   {f}: {size/1e6:.1f} Mo")
