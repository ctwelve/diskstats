-- Deterministic model alias seeding from canonical curated model names.
\connect diskstats

INSERT INTO public.model_alias (raw_model_name, model_id, match_method, notes)
SELECT dm.model_name, dm.model_id, 'seed_exact', 'Exact raw model_name -> curated drive_model mapping'
FROM public.drive_model dm
ORDER BY dm.model_id
ON CONFLICT (raw_model_name) DO UPDATE
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
