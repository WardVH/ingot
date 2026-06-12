# Ingot — customer discovery: 10 product-data prospects (gr-uo0)

Date: 2026-06-10
Goal: validate the wedge — *deterministic, code-based golden records as an API, minutes to first
merge* — in conversations BEFORE building more. The wedge is invalid for a prospect if nobody
there can name a recent incident where duplicate/wrongly-merged product data cost money, or an
owner of that problem.

Design partner (already in hand, not counted): **Medipim / Baldwin** — the engine is being built
against their legacy data; use them to sharpen the pitch and for a referenceable story.

## The list

Ordered by expected signal-per-hour, biased to BE/NL where Ward has network and language.

| # | Prospect | What they are | Why the wedge should hurt them |
|---|---|---|---|
| 1 | **Icecat** (Amsterdam, Euronext-listed) | Open catalog: 28M+ datasheets aggregated from 29k brands | Aggregation from thousands of brand feeds IS an identity-resolution problem; GTIN conflicts and duplicate datasheets at their scale are structural, and they sell data quality. |
| 2 | **bol.com** (Utrecht) | BeNeLux's largest marketplace | Millions of seller-submitted offers matched to catalog products by EAN; duplicate listings and EAN reuse/abuse are a notorious, public pain. Auditability matters when a wrong match delists a seller. |
| 3 | **Redcare Pharmacy** (Venlo; ex Shop Apotheke) | Europe's largest e-pharmacy, 7+ countries | One real-world product carries PZN + CNK + CIP13 + EAN across country catalogs — exactly the multi-code identity the engine already models. Cross-country catalog unification is their growth bottleneck. |
| 4 | **Newpharma** (Liège) | Belgian parapharmacy e-commerce | Ingests supplier feeds + data publishers; parapharma (ACL13/CNK) is the messiest code space. Local, reachable, small enough to buy an API instead of an MDM suite. |
| 5 | **Febelco** (Sint-Niklaas) | Belgium's largest pharma wholesaler (cooperative) | Product master across hundreds of suppliers feeding thousands of pharmacies; wrong merges propagate to ordering/invoicing. Likely runs on hand-maintained master data today. |
| 6 | **ChannelEngine** (Leiden) | Marketplace integration platform, 1300+ channels | Their product-matching step (seller catalog → existing marketplace listing by EAN) is identity resolution they must do per channel; an OEM/embed angle, not just direct SaaS. |
| 7 | **Z-Index** (The Hague) | Publisher of the Dutch G-Standaard | They *manufacture* golden records monthly, by hand and legacy tooling. Either a customer (steward tooling + audit trail) or proof the buyer persona exists; their pain narrative transfers to every national compendium (ABDATA, Vidal). |
| 8 | **GS1 Belgilux / Trustbox** (Brussels) | FMCG + healthcare product data pool | They own the code system (GTIN) and feel reuse/ambiguity pain institutionally. More partner/credibility play than customer — a GS1 nod de-risks every other sale. |
| 9 | **Corilus** (Gent) | Pharmacy software vendor (BE) | Consumes product data into pharmacy POS/ERP; every upstream duplicate becomes a support ticket. Validates demand on the *consuming* side of the chain. |
| 10 | **DocMorris** (Heerlen/CH) | The other big EU e-pharmacy | Same shape as Redcare; second data point on whether cross-country pharma catalogs are a budgeted problem or tolerated mess. |

Bench (if any of the above dead-end): Productsup (Berlin, enterprise feed syndication),
Channable (Utrecht), Vidal (Paris), ABDATA (Eschborn), Farmaline/Viata (BE).

## What to validate (Mom-Test style — past behavior, not opinions)

1. "Walk me through the last time two sources disagreed about whether something was the same
   product. What happened?"
2. "What did the last bad merge / duplicate cost you?" (money, delisting, recall scope, support
   tickets) — no incident nameable → no wedge.
3. "Who owns this today, and with what tooling?" (Excel + a person = best possible answer;
   'our MDM suite handles it' = probe for workarounds around the suite.)
4. "Have you tried to buy or build a fix? What killed it?" (price, implementation time, data
   science requirement — each maps to our wedge.)
5. "If you could POST your feeds somewhere and get explainable golden records back in an
   afternoon, what would you do with the time/headcount that frees?"

Do NOT pitch features (temporal queries, event sourcing) unprompted — note when prospects raise
audit/compliance themselves; that's the moat signal.

## Success criteria for this round

- ≥6 of 10 conversations held within ~4 weeks.
- ≥3 can name a concrete recent incident with a cost.
- ≥1 agrees to a paid pilot or design-partner arrangement on real data.
- If <2 name an incident: the wedge is wrong — revisit positioning (likely back toward
  pharma-vertical, where Medipim proves the pain) before building anything else.
