# Building an EffectDeck effect chain

EffectDeck is an iPhone app that runs an effect chain on the audio of other
apps. The built-in effects are EffeTune's, and a chain is a JSON list of them
that the app imports. The request names both versions, for example
`EffectDeck v2026.09.22 (EffeTune DSP 0.13.0)`. The effect names and keys for
it are in the folder named after the EffeTune DSP version,
[`chain/v0.13.0/`](chain/v0.13.0/index.md): the effect list (`index.md`) and
one file per category. If the request does not name the versions, ask the
user; EffectDeck shows them in **Settings → About** (*App version* and
*EffeTune DSP*). If there is no folder for that EffeTune DSP version, that
EffectDeck is too old to import a chain this way: tell the user to update
EffectDeck, and do not build the chain.

## In short (follow these even if you read nothing else)

1. Open the effect list before you write anything. If you cannot open it,
   say so in your first line and ask the user to paste it. Never write effect
   names or keys from memory.
2. Use only effect names and keys from that list, spelled exactly.
3. Hand over the whole chain as a tappable link that you build by running
   code (see *Handing the chain over*). Do not paste the JSON as well; the
   link is all the user needs.
4. **Always say how to import it**, right next to the link (or the code
   block): tap the link; for a code block, copy it, then **Presets** →
   **Import from clipboard** in EffectDeck. A reply without these steps is
   unusable.
5. Do not claim you opened a page, ran code or fetched a file when you did not.
6. If you cannot do part of the job reliably, say plainly that it is a limit
   of the AI model you are running on, not of EffectDeck, and recommend a
   paid, more capable model with room to think that can open links and run
   code. Never tell the user that EffectDeck failed when the chain you wrote
   is wrong.

## Before anything else

This document relies on links: the effect list, one file per category, and
[JSFX.md](JSFX.md) for anything the built-in effects cannot do. Handing a
chain over as a link needs code to run, and handing over a JSFX works best as
a file.

**If you cannot open the linked documents, cannot run code, or cannot create
files, say so plainly in one line before anything else, and say which
fallback you use:**

- cannot open the links: ask the user to paste the page you need. Do not
  write a chain from memory.
- cannot run code: you cannot build the link. Say that this AI model cannot
  run code and recommend a model that can (see *In short*, rule 6). Only if
  the user still wants the chain from you, hand it over as one `json` code
  block (see *Handing the chain over*).
- cannot create files: a JSFX goes in a code block (JSFX.md, *Handing the
  script over*).

Never guess what a page says when you could not open it.

When you use a fallback, say it is a limit of this AI model, not of EffectDeck
(see *In short*, rule 6).

## Composing contract (read this first)

Hard rules, in order of how often they are broken:

1. **Use only effect names (`nm`) from the effect list**, spelled exactly as
   listed. EffeTune's own docs, `effects-v1.json` and the `chain-v1` schema
   use other names and keys; never take names or keys from them.
2. **Use only the keys listed for that effect** in its category file, in the
   listed shape: scalar `"vl"`, indexed `"f0"` … `"f4"`, object array
   `"bs":[{…},…]`, or flat array `"dm":[…]`. Never write an indexed parameter
   as one array (`"f":[…]`).
3. **Write only what you change.** Keys you leave out keep the defaults shown
   in the category file.
4. **Stored values, inside the listed range.** Options as one of the listed
   strings, switches as `true` or `false`. Some values are stored scaled and
   the category file marks them: **ln(Hz)** (Tilt EQ `f0`, Modal Resonator
   `fr` `lp` `hp`; `6.91` is 1 kHz) and **10^x** exponents. Where a value
   says *only*, no other value is accepted.
5. **Strict JSON**: no comments, no trailing commas, no units in values,
   no `…`.
6. **Never write `external`, `externalInstance`, `externalState`, `ir`, `ib`
   or `ob`.** Write `ch` only when the user asks for one side of the stereo
   signal, or an EQ file has separate left and right parts (see *Equalizer
   APO and AutoEQ files*): `"ch":"L"` or `"ch":"R"`.
7. **Do not use an effect the list marks *Not for chains*.**
8. **Keep the chain at or below 0 dB overall.** If any effect adds gain,
   end the chain with `Volume` set to take it back out.
9. **No Audio Units in the JSON.** See *Audio Units*.
10. **Hand over the whole chain**, also after a change. See *Handing the
    chain over*.

If a rule conflicts with what you know about EffeTune, this document wins.

## Where to look things up

Replace `0.13.0` with the EffeTune DSP version the request names.

| | |
|---|---|
| Every effect name, with what it is for | <https://raw.githubusercontent.com/satomasahiro2005/EffectDeck/main/chain/v0.13.0/index.md> |
| Keys, ranges, options and defaults | one file per category, linked from the effect list, for example <https://raw.githubusercontent.com/satomasahiro2005/EffectDeck/main/chain/v0.13.0/eq.md> |
| The same, as JSON | <https://raw.githubusercontent.com/satomasahiro2005/EffectDeck/main/chain/v0.13.0/effects.json> |
| What an effect does (not its keys) | EffeTune's `docs/plugins` at the `dsp-v0.13.0` tag: <https://github.com/Frieve-A/effetune/tree/dsp-v0.13.0/docs/plugins> |

## The chain

A JSON array with one element per stage, in signal order:

- an effect: `{"nm":"<name>", <the keys you change>}`. Add `"en":false` to
  put it in switched off.
- a Section: `{"nm":"Section","cm":"Drums"}`. It groups the stages after it,
  up to the next Section, so the user can switch the group with one toggle.
  **Most chains need no Section.** Add one only when the user asks for
  groups, or when the chain has clearly separate parts the user will want to
  switch on and off on their own (for example room correction and a colour
  effect). Never put a Section around a single stage.
- a JSFX the user has imported: `{"jsfx":"<its desc: name>"}`. See *When the
  built-in effects are not enough*.

Start from this shape:

```json
[{"nm":"Hi Pass Filter","fr":30},{"nm":"5Band PEQ","f0":100,"g0":2,"t0":"ls"},{"nm":"Saturation","dr":2,"gn":-3},{"nm":"Volume","vl":-3}]
```

## When the built-in effects are not enough

If part of what the user wants cannot be done with the built-in effects,
write that part as a JSFX, following [JSFX.md](JSFX.md), and use it in the
chain:

1. Hand the JSFX over first, in its own reply, as JSFX.md describes. Tell the
   user to import it (**Import JSFX**) before the chain.
2. Then hand over the chain, with the JSFX as a stage named by its `desc:`
   line: `{"jsfx":"Tape Wobble"}` for a script that starts with
   `desc:Tape Wobble`. The app looks the name up among the JSFX the user has
   imported: the exact spelling first, then ignoring case.
3. A chain cannot set a JSFX's sliders. It starts at the script's defaults,
   so give the script defaults that suit this chain.

If the user has not imported the JSFX, the app skips that stage and says so.

## Equalizer APO and AutoEQ files

When the user gives an Equalizer APO config or an AutoEQ `ParametricEQ.txt`,
turn it into a chain:

- Each `Filter N: ON <type> Fc <Hz> Gain <dB> Q <q>` line becomes one band of
  a `15Band PEQ`, in file order (`f`, `g`, `q`, `t` at the same index). Types:
  `PK`→`"pk"`, `LS`/`LSC`→`"ls"`, `HS`/`HSC`→`"hs"`, `LP`/`LPQ`→`"lp"`,
  `HP`/`HPQ`→`"hp"`, `BP`→`"bp"`, `NO`→`"no"`, `AP`→`"ap"`. Skip `OFF` lines.
  Leave unused bands as they are (0 dB). More than 15 filters: continue in a
  second `15Band PEQ`.
- `Channel: L` and `Channel: R` parts that differ become one `15Band PEQ`
  with `"ch":"L"` and one with `"ch":"R"`. Parts that are the same stay one
  effect without `ch`. Other channels (C, SUB, RL…) cannot be used here; say
  so.
- `Preamp: <dB>` becomes a `Volume` at the end with that value.
- Say which lines you could not turn into the chain (`GraphicEQ`, `Include`,
  `Convolution`, `Delay`, and so on) instead of dropping them silently.

**Other parametric EQ formats work the same way.** EffectDeck only imports the
chain you write, so the source format does not matter: a Wavelet, Peace,
Poweramp or Qudelix export, a Roon or foobar2000 preset, or a filter table on a
web page. Read each filter's type, frequency, gain and Q and map them as above.
A `GraphicEQ` curve is not a list of filters; use the same source's parametric
version instead (AutoEq always has one).

**When the user names headphones or earphones instead of giving a file,**
fetch the correction yourself:

- Look the model up in [AutoEq](https://github.com/jaakkopasanen/AutoEq)
  (`results/INDEX.md` lists every model with its measurement source) and open
  its `ParametricEQ.txt` (the raw file). Other published corrections for the
  model (oratory1990's lists, for example) are fine too.
- If there are several measurements of the model, pick one and say which
  source you used. If the model is not there, or you cannot open the page, say
  so and ask the user for the file. Never write the filters from memory.
- A correction chain holds the correction only: the `15Band PEQ` stages and
  the `Volume` for the preamp. Do not add other effects to it.

## Audio Units

Never put an Audio Unit in the JSON; a chain cannot load one. If an AUv3
plug-in would do part of the job better, you may name it as a suggestion,
for the user to add by hand after importing the chain (**Add Effect →
Plugins**).

## What the app does with mistakes

The app still reads a chain that is not quite right, and after importing it
says in one line what it changed:

| Mistake | What happens |
|---|---|
| Unknown effect name | The stage is skipped (*Not found*) |
| Unknown key | Ignored (*Ignored*) |
| Option not in the list | Ignored; the default stays (*Ignored*) |
| Value outside the range | Set to the nearest end of the range (*Limited*) |
| `ch` the app does not know | Ignored; both sides are processed (*Ignored*) |
| JSFX the user has not imported | The stage is skipped (*Not found*) |

These notes come from mistakes in the chain, not from EffectDeck. When the user
reports one, fix the chain and hand it over again.

Text around the JSON is fine. The app looks through the code blocks in what
the user copies, `json` blocks first, and takes the first chain it finds, so
keep the chain the only `json` code block in its reply.

## Self-check before handing it over

Run this list silently. Do not list it, tick it or say that the chain passed
it; the user only needs the chain. Mention a point only if the chain still
breaks it and you cannot fix it.

- [ ] every `nm` is in the effect list, spelled exactly, and not marked *Not for chains*
- [ ] every key is listed for its effect, in the listed shape
- [ ] every value is inside its range; ln(Hz) and 10^x values are converted
- [ ] no `external`, `ir`, `ib`, `ob` and no Audio Unit; `ch` only if asked
- [ ] strict JSON that parses
- [ ] the chain ends at or below 0 dB
- [ ] no Section unless the user asked for groups or the parts really need separate switches
- [ ] every `{"jsfx":…}` names the `desc:` of a script the user has imported
- [ ] the reply carries the whole chain
- [ ] the reply says how to import it, right next to the link or code block
- [ ] a correction chain holds only the correction and ends with the Output Correction steps

## Handing the chain over

The user imports exactly what you hand over. They cannot put a chain together
from pieces.

- **Always the whole chain**, also after a change. Never only the stages that
  changed.
- **If you can run code:** build a link from the exact JSON by running code,
  and give it as a tappable link: `https://effectdeck.nemut.ai/?p=` followed
  by the standard base64 of the UTF-8 JSON, with every `+` written as `%2B`.
  In Python:

  ```python
  import base64, json
  chain = [...]  # the chain you are handing over
  data = json.dumps(chain, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
  link = "https://effectdeck.nemut.ai/?p=" + base64.b64encode(data).decode().replace("+", "%2B")
  ```

  Give only the link. Do not paste the JSON as well.
- **If you cannot run code:** you cannot build the link, and base64 written by
  hand is always wrong. Say that this AI model cannot run code and recommend a
  model that can. Only if the user still wants the chain from you, give it as
  one `json` code block.
- **Tell the user how to import it**, in one line:
  - the link: tap it. With EffectDeck installed it opens there, and the app
    asks before it replaces the current chain.
  - only if you had to give a code block: copy it, then in EffectDeck open
    **Presets** (the stacked-squares button at the top right) and tap
    **Import from clipboard**.
- Then one short line per stage: why it is there and what to adjust.
- **For a correction chain** (headphones or a speaker, from AutoEq or an
  Equalizer APO file), end with these steps, in two or three short lines: save
  the imported chain as a preset (**Presets** → **Save current chain**, named
  after the headphones), then tap the **Output Correction** row at the bottom
  of the chain, choose the output and pick that preset. The correction then
  follows that output by itself and runs after the main chain, so the main
  chain stays free for other effects.
