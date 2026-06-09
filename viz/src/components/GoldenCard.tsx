import { motion } from "motion/react";
import type { VariantView } from "../lib/types";

const chipClass = (code: string) =>
  code.startsWith("cnk:") ? "chip cnk" : code.startsWith("gtin:") ? "chip gtin" : "chip";

// One golden record, as known on the scrubbed date. Materializes (scale + fade) when it first
// becomes resolvable; its code chips stagger in, the canonical CNK highlighted gold.
export default function GoldenCard({ variant }: { variant: VariantView }) {
  return (
    <motion.div
      className="card golden"
      layout
      initial={{ opacity: 0, y: 18, scale: 0.95 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: 18, scale: 0.95 }}
      transition={{ type: "spring", stiffness: 260, damping: 26 }}
    >
      {variant.product != null && <span className="card-product">product {variant.product}</span>}
      <div className="card-key">
        variant <b>{variant.key}</b>
      </div>

      <motion.div
        className="chips"
        initial="hidden"
        animate="show"
        variants={{ show: { transition: { staggerChildren: 0.06, delayChildren: 0.12 } } }}
      >
        {variant.codes.map((code) => (
          <motion.span
            key={code}
            className={chipClass(code)}
            variants={{ hidden: { opacity: 0, y: 8 }, show: { opacity: 1, y: 0 } }}
          >
            {code}
          </motion.span>
        ))}
      </motion.div>

      {variant.attributes.length > 0 && (
        <div className="attrs">
          {variant.attributes.map((a) => (
            <div className="attr" key={a.field}>
              <span className="f">{a.field}</span>
              <span className={`v ${a.status}`}>{a.value}</span>
            </div>
          ))}
        </div>
      )}
    </motion.div>
  );
}
