# Microdatabase mirrors

An owning plugin uses the external location manifest at `rcorpus/specs/external-mirror-locations.yml`. Its default destination under each external root is `corpora/rstack-plugins/<plugin-id>-mirror`. The plugin's `config.yml` records its resolved locations at `rstack.backup.mirrors`; those entries are authoritative and can be edited independently for that plugin. Preserve each location's `require_mount` and encryption setting.

Never sync to an absent mount. A changed destination does not authorize deleting or replacing the previous mirror. Preserve existing content in place and migrate it only after checking the new destination and its mount. Private-tier records must remain sealed or omitted on external mirrors.
