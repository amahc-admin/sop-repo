-- The frontend's department list is a hardcoded display constant
-- (DEPARTMENTS in web/index.html), not read from this table -- so
-- renaming "Exec Admin" to "General HR" there is what actually changes
-- what people see. This just keeps the departments row's own name in
-- sync with that, in case it's ever read directly (e.g. from the
-- Supabase dashboard) or wired up again later. The id ('exec') and
-- code ('EXA') are untouched, so nothing that keys off them -- SOPs,
-- Anj Tino's Directory entry, My Queue's department scoping -- moves.
update departments set name = 'General HR' where id = 'exec';
