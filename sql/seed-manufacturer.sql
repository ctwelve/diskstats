-- Manufacturer seed data for curated drive_model facts.
\connect diskstats

INSERT INTO public.manufacturer (manufacturer_id, name, website, headquarters_country, notes) VALUES
  (1, 'Unknown', NULL, NULL, 'Fallback manufacturer for unclassified models.'),
  (2, 'Western Digital', 'https://www.westerndigital.com', 'United States', 'Includes WD/WDC branded and WUH/WDS-prefixed model strings.'),
  (3, 'HGST', 'https://www.westerndigital.com', 'United States', 'Historical Hitachi Global Storage Technologies brand.'),
  (4, 'Seagate', 'https://www.seagate.com', 'Ireland', 'Includes ST-prefixed model strings and Seagate-branded names.'),
  (5, 'Toshiba', 'https://www.toshiba.com', 'Japan', 'Toshiba storage product lines.'),
  (6, 'Samsung', 'https://www.samsung.com', 'South Korea', 'Samsung HDD/SSD model strings.'),
  (7, 'Micron', 'https://www.micron.com', 'United States', 'Includes Micron enterprise SSD families and MTF* model prefixes.'),
  (8, 'Crucial', 'https://www.crucial.com', 'United States', 'Consumer Micron brand (for CT*-prefixed models).'),
  (9, 'Intel', 'https://www.intel.com', 'United States', 'Legacy Intel SSD model prefixes (for SSDSCK*).'),
  (10, 'HP', 'https://www.hp.com', 'United States', 'HP-branded SSD strings.'),
  (11, 'Dell', 'https://www.dell.com', 'United States', 'Dell BOSS/virtual disk identifiers.')
ON CONFLICT (manufacturer_id) DO UPDATE
SET
  name = EXCLUDED.name,
  website = EXCLUDED.website,
  headquarters_country = EXCLUDED.headquarters_country,
  notes = EXCLUDED.notes;

SELECT pg_catalog.setval(
  'public.manufacturer_manufacturer_id_seq',
  COALESCE((SELECT max(manufacturer_id) FROM public.manufacturer), 1),
  EXISTS (SELECT 1 FROM public.manufacturer)
);
