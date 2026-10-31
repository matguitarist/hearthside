#!/bin/bash
# The world tables scripts/questdb.py reads, as TSV on stdout: read-only SELECTs against a CMaNGOS
# Classic world database in the launcher's container. Run it where the container is:
#   ssh root@server bash -s < scripts/questdb-dump.sh > world.tsv
set -euo pipefail
db=${DB_CONTAINER:-azeroth-survivors-cmangos-database-1}
q() { echo "#$1"; docker exec "$db" mariadb -umangos -pmangos -N -B classicmangos -e "$2"; }
q quest "select entry, Title, QuestLevel, MinLevel, RequiredRaces, ZoneOrSort, ObjectiveText1, ObjectiveText2, ObjectiveText3, ObjectiveText4, ReqItemId1, ReqItemId2, ReqItemId3, ReqItemId4, ReqCreatureOrGOId1, ReqCreatureOrGOId2, ReqCreatureOrGOId3, ReqCreatureOrGOId4, ReqSpellCast1, ReqSpellCast2, ReqSpellCast3, ReqSpellCast4 from quest_template"
q ctpl "select Entry, Name, LootId from creature_template"
q cspawn "select id, map, round(position_x), round(position_y) from creature where map in (0, 1)"
q gtpl "select entry, type, name, data1 from gameobject_template"
q gspawn "select id, map, round(position_x), round(position_y) from gameobject where map in (0, 1)"
q cloot "select entry, item, ChanceOrQuestChance from creature_loot_template where mincountOrRef > 0"
q gloot "select entry, item, ChanceOrQuestChance from gameobject_loot_template where mincountOrRef > 0"
q item "select entry, name from item_template"
q cend "select id, quest from creature_involvedrelation"
q gend "select id, quest from gameobject_involvedrelation"
# For scripts/infodb.py: what a vendor pays for each item, and each spawned creature's health.
q sell "select entry, SellPrice from item_template where SellPrice > 0"
q health "select t.Name, min(t.MinLevel), max(t.MaxLevel), min(t.MinLevelHealth), max(t.MaxLevelHealth) from creature_template t where t.MaxLevelHealth > 0 and exists (select 1 from creature c where c.id = t.Entry) group by t.Name"
