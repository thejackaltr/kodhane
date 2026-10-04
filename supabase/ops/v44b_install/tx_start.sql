-- PARTIAL of supabase/ops/kodhane_v44b_install.sh: transaction settings (dry-run / install / rollback). B's ALTER TABLE
-- takes an ACCESS EXCLUSIVE lock on kodhane_saves: wait at most 5 s for it (else error, nothing changed; retry), so
-- player writes never queue behind the install for long.
set local lock_timeout = '5s';
set local statement_timeout = '120s';
