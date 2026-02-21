-- Deterministic model alias seeding from canonical curated model names.
\connect diskstats

INSERT INTO public.model_alias (provider_id, raw_model_name, model_id, match_method, notes)
SELECT p.provider_id, dm.model_name, dm.model_id, 'seed_exact', 'Exact raw model_name -> curated drive_model mapping'
FROM public.provider p
CROSS JOIN public.drive_model dm
WHERE p.name = 'backblaze'
ORDER BY dm.model_id
ON CONFLICT (provider_id, raw_model_name) DO UPDATE
SET
  model_id = EXCLUDED.model_id,
  match_method = EXCLUDED.match_method,
  notes = EXCLUDED.notes,
  is_active = true;

SELECT pg_catalog.setval(
  'public.model_alias_alias_id_seq',
  COALESCE((SELECT max(alias_id) FROM public.model_alias), 1),
  EXISTS (SELECT 1 FROM public.model_alias)
);
