# frozen_string_literal: true

# Run by the setup service (rails runner) after the migrations, on every
# `docker compose up`; safe to repeat.
#
# - First run (no organization yet): the organization, its billing entity
#   and the admin user (like Lago's `signup:seed_organization`, which the
#   official compose runs with LAGO_CREATE_ORG), plus the initial settings:
#   country, currency and document language of the organization and its
#   billing entity, and a tax (IVA 19%) applied to it by default. All in one
#   transaction: a failed run is repeated. Later changes in the app are kept.
#   (Lago's task finds the organization by name: renaming it in the app would
#   create a second one on the next run; this script doesn't.)
# - Every run: the admin user (LAGO_ADMIN_EMAIL) exists with an admin
#   membership (its password is only set when it's created), and the API key
#   LAGO_API_KEY, if set, exists.

def env(name, default = nil)
  value = ENV[name]
  value.nil? || value.empty? ? default : value
end

def ensure_admin(organization)
  email = env("LAGO_ADMIN_EMAIL")
  user = User.find_by(email:)
  unless user
    user = User.create!(email:, password: env("LAGO_ADMIN_PASSWORD"))
    puts "Admin user #{email} created"
  end
  membership = Membership.find_or_create_by!(user:, organization:)
  admin_role = Role.find_or_create_by!(admin: true)
  MembershipRole.find_or_create_by!(membership:, organization:, role: admin_role)
end

# Partitioning of enriched_events (Lago's migration 20260109132143): on a new
# database Rails loads db/structure.sql instead of running the migrations,
# and the dump has the partitioned table and its default partition but not
# pg_partman's configuration (data) nor the monthly partitions (excluded), so
# pg_partman never manages the table. Do what the migration does, while the
# default partition is still empty.
def partition_enriched_events
  conn = ActiveRecord::Base.connection
  return unless conn.select_value("SELECT 1 FROM pg_extension WHERE extname = 'pg_partman'")
  return unless conn.select_value("SELECT 1 FROM pg_class WHERE relname = 'enriched_events' AND relkind = 'p'")
  return if conn.select_value("SELECT 1 FROM partman.part_config WHERE parent_table = 'public.enriched_events'")

  if conn.select_value("SELECT count(*) FROM public.enriched_events_default").to_i.positive?
    warn "enriched_events isn't managed by pg_partman and its default partition has data: left as is"
    return
  end
  ActiveRecord::Base.transaction do
    conn.execute("DROP TABLE IF EXISTS public.enriched_events_default")
    conn.execute("DROP TABLE IF EXISTS partman.template_public_enriched_events")
    conn.execute(<<~SQL)
      SELECT partman.create_parent(
        p_parent_table := 'public.enriched_events', p_control := 'timestamp',
        p_interval := '1 month', p_type := 'range', p_premake := 3,
        p_start_partition := '2024-12-01'
      )
    SQL
    conn.execute(<<~SQL)
      UPDATE partman.part_config
      SET infinite_time_partitions = true, retention = '14 months', retention_keep_table = true
      WHERE parent_table = 'public.enriched_events'
    SQL
  end
  puts "enriched_events partitioned with pg_partman"
end

partition_enriched_events

ActiveRecord::Base.transaction do
  organization = Organization.order(:created_at).first

  if organization.nil?
    currency = env("LAGO_CURRENCY", "CLP").upcase
    country = env("LAGO_COUNTRY", "CL").upcase
    locale = env("LAGO_DOCUMENT_LOCALE", "es")
    name = env("LAGO_ORG_NAME", "Lago")
    puts "Initial settings (#{name}: #{country}, #{currency}, documents in #{locale})"

    organization = Organization.create!(
      name:, country:, default_currency: currency, document_locale: locale
    )
    billing_entity = BillingEntity.create!(
      id: organization.id, organization:, name:, code: name.parameterize,
      country:, city: env("LAGO_CITY", "Santiago"), default_currency: currency,
      document_locale: locale
    )
    ApiKey.find_or_create_by!(organization:)

    rate = env("LAGO_TAX_RATE")
    if rate
      tax = Tax.create!(
        organization:, code: env("LAGO_TAX_NAME", "IVA").parameterize(separator: "_"),
        name: env("LAGO_TAX_NAME", "IVA"), rate: rate.to_f, applied_to_organization: true
      )
      BillingEntity::AppliedTax.create!(billing_entity:, tax:, organization:)
    end
  end

  ensure_admin(organization)

  api_key = env("LAGO_API_KEY")
  if api_key && !ApiKey.exists?(organization:, value: api_key)
    # ApiKey generates its value on create (like Lago's task: create, then
    # set the value).
    stack_key = ApiKey.find_or_create_by!(organization:, name: "Stack")
    stack_key.update!(value: api_key)
    puts "API key from LAGO_API_KEY set"
  end
end

puts "Settings OK"
