-- 25/11/2026 : CES désactivée par défaut (migration ces_desactivee_par_defaut).
-- Désactivée = onglet « Soutien social — CES » invisible pour tout le monde, propriétaire compris (app).
alter table public.ca_meta alter column ces_actif set default false;
