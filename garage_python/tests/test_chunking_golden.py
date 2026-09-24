"""Chunk output pinned against recorded goldens.

``golden/chunking.json`` was recorded from the langchain-text-splitters based
chunker this package used before :mod:`garage_rag.ingest.splitters` replaced it.
Every chunk's text, ordinal, chunker id, heading path and offsets must match, so
an index built by either implementation is identical and re-ingest rebuilds
nothing. A deliberate change regenerates the file::

    python tests/test_chunking_golden.py --regenerate

and, if the output differs, changes the chunker id so stored chunks are rebuilt.
"""

from __future__ import annotations

import json
import sys
from dataclasses import asdict
from pathlib import Path

import pytest

from garage_rag.extract.base import ContentKind
from garage_rag.ingest.chunking import chunk_text

GOLDEN = Path(__file__).parent / "golden" / "chunking.json"

MARKDOWN = """# Boot Security

Intro paragraph about the boot chain. It covers the ROM, iBoot and the kernel.

## SEP

The Secure Enclave Processor validates its own firmware. It keeps keys away from the AP.

### FIPS Mode

FIPS mode changes the key derivation path.

```python
# not a header inside a fence
def f():
    return 1
```

## EEPROM

Some notes about EEPROM contents.
~~~
## also not a header
~~~

#### Deep heading is not split on

#NoSpace is not a header either
##
Trailing text under an empty heading.
"""

PROSE = (
    " ".join(
        f"Sentence {i} talks about the boot chain; it has clauses, commas, and questions? Yes! Indeed."
        for i in range(40)
    )
    + "\n\n"
    + "\n".join(f"Line {i} of a list." for i in range(30))
)

UNICODE = "Café déjà vu — naïve façade. " * 60 + "\n\n" + "日本語の文章です。" * 80

LONG_TOKEN = "x" * 3000

CRLF = "First paragraph line one.\r\nLine two.\r\n\r\nSecond paragraph " + ("word " * 80) + "\r\n"

CODE = {
    ".py": '''import os


class Gamma:
    """A class."""

    def method(self):
        return None

\tdef tabbed(self):
\t\treturn 1


def alpha(x):
    """First."""
    if x:
        return x + 1
    for i in range(3):
        print(i)
    return x


def beta(y):
    return y * 2
'''
    * 4,
    ".js": """const a = 1;
let b = 2;
var c = 3;
function add(x, y) {
  return x + y;
}
class Box {
  constructor(v) { this.v = v; }
}
if (a) {
  console.log(a);
}
for (let i = 0; i < 3; i++) {}
while (false) {}
switch (a) {
case 1:
  break;
default:
  break;
}
"""
    * 4,
    ".ts": """enum Color { Red, Green }
interface Shape { area(): number }
namespace NS { export const x = 1; }
type Alias = string;
class Square implements Shape {
  area() { return 4; }
}
function f(): void {}
const g = () => 1;
"""
    * 5,
    ".go": """package main

import "fmt"

type Point struct {
	X, Y int
}

var global = 1

const limit = 10

func main() {
	for i := 0; i < limit; i++ {
		fmt.Println(i)
	}
	if global > 0 {
		switch global {
		case 1:
			fmt.Println("one")
		}
	}
}
"""
    * 4,
    ".rs": """fn main() {
    let x = 5;
    if x > 1 {
        println!("big");
    }
    loop {
        break;
    }
    match x {
        _ => {}
    }
}
const MAX: u32 = 10;
fn helper(v: u32) -> u32 {
    while v > 0 {}
    for i in 0..v {}
    v
}
"""
    * 4,
    ".swift": """import Foundation

struct Point {
    var x: Int
}

enum Kind { case a, b }

class Store {
    func load() {
        if true {
            for i in 0..<3 { print(i) }
        }
        do {
            try run()
        } catch {}
        switch 1 {
        case 1: break
        default: break
        }
    }
}

func run() throws {}
"""
    * 4,
    ".java": """package demo;

public class Main {
    private static int count = 0;
    protected void run() {}
    public static void main(String[] args) {
        if (count == 0) {
            for (int i = 0; i < 3; i++) {}
        }
        while (false) {}
        switch (count) {
        case 0: break;
        }
    }
}
static class Helper {}
"""
    * 4,
    ".c": """#include <stdio.h>

int counter = 0;
float ratio = 1.0;
double precise = 2.0;

void tick(void) {
    counter++;
}

int main(void) {
    if (counter == 0) {
        for (int i = 0; i < 3; i++) tick();
    }
    while (0) {}
    switch (counter) {
    case 3: break;
    }
    return 0;
}
"""
    * 4,
    ".cpp": """#include <vector>

class Widget {
public:
    int size() const { return 0; }
};

void use(Widget& w) {
    for (auto i = 0; i < w.size(); ++i) {}
}
"""
    * 6,
    ".rb": """class Greeter
  def greet(name)
    if name
      puts name
    end
    unless name
      puts "nobody"
    end
    while false do end
    for i in 1..3 do end
    begin
      raise "x"
    rescue
      nil
    end
  end
end
"""
    * 4,
    ".php": """<?php
function hello() {
    echo "hi";
}
class A {}
if (true) {}
foreach ([1, 2] as $x) {}
while (false) {}
do {} while (false);
switch (1) {
case 1: break;
}
"""
    * 5,
    ".kt": """package demo

class A
public fun one() = 1
protected val two = 2
private var three = 3
internal fun four() {}
companion object {}
fun five() {
    if (true) {}
    for (i in 1..3) {}
    while (false) {}
    when (1) { else -> {} }
}
val six = 6
var seven = 7
"""
    * 4,
    ".scala": """object Main {
  def main(args: Array[String]): Unit = {}
}
class Point(x: Int)
val a = 1
var b = 2
def f(x: Int) = x match {
  case 1 => "one"
}
if (true) {}
for (i <- 1 to 3) {}
while (false) {}
"""
    * 5,
    ".cs": """using System;

interface IShape {}
enum Color { Red }
delegate void Handler();
public class Program
{
    static void Main()
    {
        try { } catch { } finally { }
        foreach (var x in new int[0]) { }
        return;
    }
}
abstract class Base {}
private class Hidden {}
protected class Guarded {}
"""
    * 4,
    ".lua": """local x = 1
function f(a)
  if a then
    return a
  end
  for i = 1, 3 do end
  while false do end
  repeat until true
end
"""
    * 6,
    ".pl": """#!/usr/bin/perl
use strict;
sub greet {
    my ($name) = @_;
    print "Hello $name\\n";
}
greet("world");
"""
    * 8,
    ".hs": """module Main where

import qualified Data.Map as M
import Data.List

data Tree = Leaf | Node Tree Tree
newtype Wrap = Wrap Int
type Name = String

class Shape a where
  area :: a -> Double

instance Shape Tree where
  area _ = 0

main :: IO ()
main = do
  let x = 1
  case x of
    1 -> print x
    _ -> return ()
  where
    y = 2
"""
    * 4,
    ".ex": """defmodule Greeter do
  defprotocol P do
  end
  defmacro m do
  end
  defmacrop mp do
  end
  def hello(name) do
    if name do
      name
    end
    unless name do
    end
    case name do
      _ -> nil
    end
    cond do
      true -> nil
    end
    with {:ok, x} <- {:ok, 1} do
      x
    end
    for x <- [1] do
      x
    end
  end
  defp secret, do: nil
end
"""
    * 3,
    ".html": """<html>
<head><title>Page</title><meta charset="utf-8"><style>p { color: red; }</style></head>
<body>
<header><nav><ul><li>One</li><li>Two</li></ul></nav></header>
<div><h1>Title</h1><h2>Sub</h2><h3>Minor</h3><p>Paragraph text<br>with a break.</p>
<span>inline</span><ol><li>first</li></ol>
<table><tr><th>A</th><td>1</td></tr></table>
<h4>h4</h4><h5>h5</h5><h6>h6</h6></div>
<script>console.log(1)</script>
<footer>End</footer>
</body>
</html>
"""
    * 3,
    ".tex": r"""\documentclass{article}
\begin{document}
\chapter{One}
\section{Intro}
Text with inline math $x^2$ and display math $$y = mx + b$$.
\subsection{Detail}
\subsubsection{More}
\begin{enumerate}
\item first
\end{enumerate}
\begin{itemize}
\item a
\end{itemize}
\begin{description}\item[x] y\end{description}
\begin{list}{}{}\item z\end{list}
\begin{quote}q\end{quote}
\begin{quotation}qq\end{quotation}
\begin{verse}v\end{verse}
\begin{verbatim}raw\end{verbatim}
\begin{align}a &= b\end{align}
\end{document}
"""
    * 3,
    ".sol": """pragma solidity ^0.8.0;
using SafeMath for uint;
contract Token {
    event Transfer(address to);
    modifier onlyOwner() { _; }
    error Bad();
    struct S { uint a; }
    enum E { A }
    constructor() {}
    function f() public {
        if (true) {}
        for (uint i; i < 1; i++) {}
        while (false) {}
        assembly {}
    }
}
interface I {}
library L {}
type T is uint;
"""
    * 3,
    ".cob": """IDENTIFICATION DIVISION.
PROGRAM-ID. HELLO.
ENVIRONMENT DIVISION.
INPUT-OUTPUT SECTION.
FILE SECTION.
DATA DIVISION.
WORKING-STORAGE SECTION.
01 WS-NAME PIC A(10).
LINKAGE SECTION.
PROCEDURE DIVISION.
OPEN INPUT F.
READ F.
WRITE R.
CLOSE F.
IF WS-NAME = SPACES
ELSE
MOVE "X" TO WS-NAME.
PERFORM UNTIL WS-NAME = "Y"
PERFORM VARYING I FROM 1 BY 1 UNTIL I > 3
ACCEPT WS-NAME.
DISPLAY WS-NAME.
STOP RUN.
"""
    * 4,
    ".xyz": "unmapped extension text\n\nwith paragraphs " * 30,
}

TABULAR = (
    "## Sheet1\n"
    + "\n".join(f"row {i} | value {i} | note {i}" for i in range(60))
    + "\n\n## Sheet2\n"
    + ("\n".join(f"x{i} | y{i}" for i in range(40)))
)

EDGE = {
    "empty": "",
    "whitespace": "   \n\n  \t ",
    "short": "hi",
    "long-token": LONG_TOKEN,
    "crlf": CRLF,
    "unicode": UNICODE,
    "only-separators": "\n\n\n. . . , , ,",
}

# (size, overlap) pairs; overlap larger than short inputs on purpose.
PROSE_PARAMS = [(1000, 100), (200, 20), (120, 60), (50, 0)]
CODE_PARAMS = [(1500, 150), (300, 30), (80, 40)]


def _cases() -> list[tuple[str, str, ContentKind, str, int, int]]:
    cases: list[tuple[str, str, ContentKind, str, int, int]] = []
    for size, overlap in PROSE_PARAMS:
        tag = f"{size}/{overlap}"
        cases.append((f"markdown {tag}", MARKDOWN, ContentKind.MARKDOWN, "", size, overlap))
        cases.append((f"markdown-crlf {tag}", MARKDOWN.replace("\n", "\r\n"), ContentKind.MARKDOWN, "", size, overlap))
        cases.append((f"markdown-hashes {tag}", "#" * 5000, ContentKind.MARKDOWN, "", size, overlap))
        cases.append((f"prose {tag}", PROSE, ContentKind.PROSE, "", size, overlap))
        cases.append((f"tabular {tag}", TABULAR, ContentKind.TABULAR, "", size, overlap))
        for name, text in EDGE.items():
            cases.append((f"prose-edge-{name} {tag}", text, ContentKind.PROSE, "", size, overlap))
            cases.append((f"markdown-edge-{name} {tag}", text, ContentKind.MARKDOWN, "", size, overlap))
    for size, overlap in CODE_PARAMS:
        tag = f"{size}/{overlap}"
        for ext, text in CODE.items():
            cases.append((f"code{ext} {tag}", text, ContentKind.CODE, ext, size, overlap))
            cases.append((f"code{ext}-crlf {tag}", text.replace("\n", "\r\n"), ContentKind.CODE, ext, size, overlap))
        for name, text in EDGE.items():
            cases.append((f"code-edge-{name} {tag}", text, ContentKind.CODE, ".py", size, overlap))
    return cases


def _record(text: str, kind: ContentKind, ext: str, size: int, overlap: int) -> list[dict]:
    return [asdict(chunk) for chunk in chunk_text(text, kind, extension=ext, size=size, overlap=overlap)]


CASES = _cases()


@pytest.fixture(scope="module")
def golden() -> dict[str, list[dict]]:
    return json.loads(GOLDEN.read_text(encoding="utf-8"))


def test_golden_covers_every_case(golden: dict[str, list[dict]]) -> None:
    assert sorted(golden) == sorted(name for name, *_ in CASES)


@pytest.mark.parametrize(("name", "text", "kind", "ext", "size", "overlap"), CASES, ids=[c[0] for c in CASES])
def test_matches_golden(
    golden: dict[str, list[dict]], name: str, text: str, kind: ContentKind, ext: str, size: int, overlap: int
) -> None:
    assert _record(text, kind, ext, size, overlap) == golden[name]


if __name__ == "__main__" and "--regenerate" in sys.argv:
    GOLDEN.parent.mkdir(exist_ok=True)
    recorded = {name: _record(text, kind, ext, size, overlap) for name, text, kind, ext, size, overlap in CASES}
    # One case per line keeps diffs readable without an indented multi-megabyte file.
    lines = [f"{json.dumps(name)}: {json.dumps(recorded[name], ensure_ascii=False)}" for name in sorted(recorded)]
    GOLDEN.write_text("{\n" + ",\n".join(lines) + "\n}\n", encoding="utf-8")
    print(f"wrote {len(recorded)} cases to {GOLDEN}")
