// トップの構造化データ（JSON-LD）。Worker の外（test.mjs）でも読めるようにアセットを import しない。

import { TEXT, FAQ } from "./text.js";
import { DECK_HOST, APP_STORE, GITHUB } from "./links.js";

export const ORIGIN = `https://${DECK_HOST}`;

// JSON-LD の answer にはタグを外した字を入れる（FAQ の a は HTML）。
export const plainText = (html) =>
  html.replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");

// トップの構造化データ。アプリ（SoftwareApplication）と FAQ（FAQPage、ページの FAQ と同じ中身）。
export function homeLd() {
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        "@id": `${ORIGIN}/#app`,
        name: "EffectDeck",
        description: TEXT.description,
        url: `${ORIGIN}/`,
        operatingSystem: "iOS 27",
        applicationCategory: "MultimediaApplication",
        downloadUrl: APP_STORE,
        installUrl: APP_STORE,
        image: `${ORIGIN}/icon.png`,
        screenshot: TEXT.shots.map((s) => `${ORIGIN}/assets/shot-${s.file}.webp`),
        offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
        isAccessibleForFree: true,
        license: "https://opensource.org/licenses/MIT",
        author: { "@type": "Organization", name: "nemut.ai", url: "https://nemut.ai/" },
        sameAs: [APP_STORE, GITHUB],
      },
      {
        "@type": "FAQPage",
        "@id": `${ORIGIN}/#faq`,
        mainEntity: FAQ.map((f) => ({
          "@type": "Question",
          name: f.q,
          acceptedAnswer: { "@type": "Answer", text: plainText(f.a) },
        })),
      },
    ],
  };
}
