-- Optional enrichment for seeded drive models and manufacturers.
-- Run after schema-cleaned.sql and (optionally) seed-drive-model.sql.
\connect diskstats

-- Manufacturer reference rows used by model enrichment mapping.
INSERT INTO public.manufacturer (manufacturer_id, name, website, headquarters_country, notes) VALUES
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

UPDATE public.drive_model
SET manufacturer_id = CASE
  WHEN model_name ~* '^(WDC|WD|WUH|WDS)' THEN 2
  WHEN model_name ~* '^(HGST|Hitachi)' THEN 3
  WHEN model_name ~* '^(ST|Seagate)' THEN 4
  WHEN model_name ~* '^TOSHIBA' THEN 5
  WHEN model_name ~* '^(SAMSUNG|Samsung)' THEN 6
  WHEN model_name ~* '^(Micron|MTF)' THEN 7
  WHEN model_name ~* '^(CT[0-9]|Crucial)' THEN 8
  WHEN model_name ~* '^SSDSCK' THEN 9
  WHEN model_name ~* '^HP ' THEN 10
  WHEN model_name ~* '^DELL' THEN 11
  ELSE COALESCE(manufacturer_id, 1)
END;

-- Coarse media classification.
UPDATE public.drive_model
SET media_type = CASE
  WHEN model_name ~* '(SSD|SSDSCK|MTF|DELLBOSS|\\bCT[0-9])' THEN 'ssd'
  WHEN model_name ~* '^(ST|WDC|WD|WUH|HGST|Hitachi|TOSHIBA|SAMSUNG HD)' THEN 'hdd'
  ELSE media_type
END;

-- Light-touch interface/form-factor enrichment when explicit in model strings.
UPDATE public.drive_model
SET interface_type = CASE
      WHEN model_name ~* 'NVME' THEN 'nvme'
      WHEN model_name ~* 'SAS' THEN 'sas'
      WHEN media_type = 'ssd' AND interface_type IS NULL THEN 'sata'
      ELSE interface_type
    END,
    form_factor = CASE
      WHEN model_name ~* '(\\b2\\.5\\b|2.5)' THEN '2.5in'
      WHEN model_name ~* '3\\.5' THEN '3.5in'
      WHEN model_name ~* '(\\bM\\.2\\b|\\bM2\\b)' THEN 'm.2'
      ELSE form_factor
    END
WHERE interface_type IS NULL OR form_factor IS NULL;

SELECT pg_catalog.setval('public.manufacturer_manufacturer_id_seq', COALESCE((SELECT max(manufacturer_id) FROM public.manufacturer), 1), EXISTS (SELECT 1 FROM public.manufacturer));
