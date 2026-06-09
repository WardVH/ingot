# lib/ingest/code_registry.ex — the single source of medipim product-code knowledge (gr-6k4).
#
# Drives scheme handling from ONE table instead of patching country-by-country. Each medipim
# products_deltas field name maps to {engine_scheme_atom, classification}, where classification
# tells ClaimMapping how to use the code:
#
#   :identity     — a national/GTIN code that BRIDGES products in clustering (cnk, cip_acl7, gtin…).
#   :external_ref — identifies the product in ANOTHER system (cbId/ospId/…). Carried as an
#                   attribute, NEVER bridges (the over-merge/bridging-policy question is its own
#                   bead, gr-ose; default here is "do not bridge").
#   :attribute    — a non-identifying classification (hsCode customs, pbs reimbursement class).
#   :entity_id    — medipim's own id (productId) == the legacy entity; not a code claim at all.
#
# The roster was extracted from medipimv2's ProductIdentifierInterface value objects +
# ProductMetaFieldBuilder / ProductCodeFactory (see docs/plans/2026-06-08-product-code-registry-design.md).
# Adding a market later is a data change here, not a code change.
#
# The engine atom — NOT the medipim field name — is what Codes canonicalizes and what clustering
# bridges on. The GTIN family (ean/gtin/eanGtin*/upc*/…) all collapse to :gtin; national codes
# keep their own atom. The only field-name ≠ canonical-code mismatch is cipOrAcl7 -> :cip_acl7.

defmodule CodeRegistry do
  # medipim field name => {engine scheme atom, classification}.
  @registry %{
    # ── identity — national codes (each its own scheme atom) ──────────────────
    "cnk" => {:cnk, :identity},
    "cipOrAcl7" => {:cip_acl7, :identity},
    "acl13" => {:acl13, :identity},
    "cip13" => {:cip13, :identity},
    "pzn" => {:pzn, :identity},
    "pznAustria" => {:pzn_austria, :identity},
    "sukl" => {:sukl, :identity},
    "pdk" => {:pdk, :identity},
    "cn" => {:cn, :identity},
    "cefip" => {:cefip, :identity},
    "nationalCode" => {:national_code, :identity},
    "ndc" => {:ndc, :identity},
    "hri" => {:hri, :identity},
    "pin" => {:pin, :identity},
    "fred" => {:fred, :identity},
    "zcode" => {:zcode, :identity},
    "lppr" => {:lppr, :identity},

    # ── identity — GTIN family (all fold to :gtin; Codes canonicalizes to GTIN-14) ─
    "ean" => {:gtin, :identity},
    "gtin" => {:gtin, :identity},
    "eanGtin8" => {:gtin, :identity},
    "eanGtin12" => {:gtin, :identity},
    "eanGtin13" => {:gtin, :identity},
    "eanGtin14" => {:gtin, :identity},
    "undefinedEanGtinCode" => {:gtin, :identity},
    "usaGtinCode" => {:gtin, :identity},
    "upc10" => {:gtin, :identity},
    "upc11" => {:gtin, :identity},
    "upc12" => {:gtin, :identity},

    # ── external-ref — identify the product in another system, do NOT bridge ──────
    "cbId" => {:cb_id, :external_ref},
    "ospId" => {:osp_id, :external_ref},
    "offisanteId" => {:offisante_id, :external_ref},
    "cisCode" => {:cis_code, :external_ref},
    "publicPageIdentifier" => {:public_page_identifier, :external_ref},

    # ── entity-id — medipim's own id == the legacy entity, not a code claim ───────
    "productId" => {:product_id, :entity_id},

    # ── attribute / classification — non-identifying ──────────────────────────────
    "hsCode" => {:hs_code, :attribute},
    "pbs" => {:pbs, :attribute}
  }

  # Unknown field => a conservative default: keep the raw field name as the scheme (NEVER
  # String.to_atom/1 on unvalidated input — the loader does not whitelist schemes, so that would
  # be an atom-table leak), classified as a non-bridging :attribute.
  @default_classification :attribute

  @doc "The full medipim field => {scheme, classification} registry."
  def table, do: @registry

  @doc """
  Engine scheme for a medipim field. Known fields map to their engine atom (GTIN family => :gtin);
  an unknown field stays its raw string (Codes.canonicalize passes unknown schemes through).
  """
  def scheme(field) do
    case Map.get(@registry, field) do
      {scheme, _class} -> scheme
      nil -> field
    end
  end

  @doc "Classification for a medipim field (:identity | :external_ref | :attribute | :entity_id)."
  def classification(field) do
    case Map.get(@registry, field) do
      {_scheme, class} -> class
      nil -> @default_classification
    end
  end

  @doc "Does this medipim field carry a bridging identity code?"
  def identity_field?(field), do: classification(field) == :identity

  @doc "The set of medipim field names classified as :identity (for the gen oracle in gr-lmt)."
  def identity_fields do
    for {field, {_scheme, :identity}} <- @registry, into: MapSet.new(), do: field
  end

  # ── bridge grade — an ORTHOGONAL axis over the engine SCHEME ATOM (gr-ose) ─────
  #
  # A SECOND, independent classification used ONLY by the over-merge guard: when a merge clusters
  # two legacy entities, is the shared bridge a NATIONAL identity code (trusted — the re-derivation
  # working as intended) or merely a reusable/reassignable BARCODE/GS1 code (suspect — medipim flags
  # such ambiguous matches as ProductCodeIdentityMatch / MED-11207)? This axis is keyed on the engine
  # scheme atom, NOT the medipim field, and is DELIBERATELY distinct from `classification/1`: acl13
  # and cip13 stay `:identity` there (they DO bridge in clustering) yet are barcode-grade here.
  @national_schemes MapSet.new([
                      :cnk,
                      :cip_acl7,
                      :cefip,
                      :pzn,
                      :pzn_austria,
                      :sukl,
                      :national_code,
                      :cn,
                      :pdk,
                      :ndc,
                      :hri,
                      :pin,
                      :lppr,
                      :fred,
                      :zcode
                    ])

  @barcode_schemes MapSet.new([:gtin, :acl13, :cip13])

  @doc """
  Bridge grade of an ENGINE SCHEME ATOM — the over-merge guard's axis (gr-ose):

    * `:national` — a national identity code (cnk, cip_acl7, …); a merge sharing one is TRUSTED.
    * `:barcode`  — a reusable/reassignable GS1/barcode code (gtin, acl13, cip13); a merge bridged
                    SOLELY by one of these is SUSPECT.
    * `:none`     — anything else (external_ref / attribute / unknown) — not a bridge.
  """
  def bridge_grade(scheme) do
    cond do
      MapSet.member?(@national_schemes, scheme) -> :national
      MapSet.member?(@barcode_schemes, scheme) -> :barcode
      true -> :none
    end
  end

  @doc "Is this engine scheme atom a national identity code (trusted bridge)?"
  def national_grade?(scheme), do: bridge_grade(scheme) == :national

  @doc "Is this engine scheme atom a GS1/barcode code (suspect bridge)?"
  def barcode_grade?(scheme), do: bridge_grade(scheme) == :barcode
end
