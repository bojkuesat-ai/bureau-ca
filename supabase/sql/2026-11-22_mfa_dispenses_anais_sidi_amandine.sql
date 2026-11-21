-- 22/11/2026 — Dispense de la double authentification obligatoire, sur décision du propriétaire
-- (même mécanisme que Najwa Hit : table mfa_dispenses, lue par mfa_concerne()).
insert into public.mfa_dispenses (membre_id, motif) values
 ('49214b18-6ca0-4a5f-9846-4a5a65a952ce','Anais Dethy : connexion par mot de passe seul, sur décision du propriétaire'),
 ('ee823462-6df2-4584-bdfa-a4c0166a6735','Sidi Ahmed Youra : connexion par mot de passe seul, sur décision du propriétaire'),
 ('ef93b7ac-539a-4a77-8ce6-a8eb36ccf064','Amandine Culot Verboekhoven : connexion par mot de passe seul, sur décision du propriétaire')
on conflict do nothing;
