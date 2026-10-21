-- The feature modules by seam name (spec §5.1), filled by control.lua once it has required them all. Modules call one
-- another through this table at run time (ct.runs.on_arrived(unit)), never by requiring each other: the seams call
-- both ways (travel and runs, registry and gui, registry and portals), require can't load a cycle, and Factorio allows
-- require only while loading. So nothing may call through ct while the modules load.
return {}
