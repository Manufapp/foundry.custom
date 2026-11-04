# Runs inside the target foundry.django image (`manage.py shell < field_defaults.py`)
# and prints every model column's default as
#   FIELD_DEFAULT<TAB>table<TAB>column<TAB>COPY text
# for prepare_dump.py, which uses it to fill columns added after the dump was taken.
# Used by ../restore_dump.sh; kept in sync with foundry.django's gcp_dump_restore.sh.
import datetime, decimal, enum, json, uuid
from django.apps import apps

def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

def copy_text(field, value):
    if value is None:
        return None
    if isinstance(value, enum.Enum):
        value = value.value
    kind = field.get_internal_type()
    if kind == "ArrayField":
        return "{}" if not value else None
    if kind == "JSONField":
        return esc(json.dumps(value))
    if isinstance(value, bool):
        return "t" if value else "f"
    if isinstance(value, (datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, (int, float, decimal.Decimal, uuid.UUID, str)):
        return esc(str(value))
    return None

for model in apps.get_models(include_auto_created=True):
    if model._meta.proxy or not model._meta.managed:
        continue
    for f in model._meta.concrete_fields:
        # A unique column can't take one shared fill value; relations have no default.
        if f.primary_key or f.is_relation or f.unique or not f.has_default():
            continue
        try:
            val = copy_text(f, f.get_default())
        except Exception:
            continue
        if val is not None:
            print(f"FIELD_DEFAULT\t{model._meta.db_table}\t{f.column}\t{val}")
