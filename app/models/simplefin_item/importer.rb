class SimplefinItem::Importer
  attr_reader :simplefin_item, :simplefin_provider

  def initialize(simplefin_item, simplefin_provider:)
    @simplefin_item = simplefin_item
    @simplefin_provider = simplefin_provider
  end

  def import
    # Determine start date based on sync history
    start_date = determine_sync_start_date

    accounts_data = simplefin_provider.get_accounts(
      simplefin_item.access_url,
      start_date: start_date
    )

    # Handle errors if present
    if accounts_data[:errors] && accounts_data[:errors].any?
      handle_errors(accounts_data[:errors])
      return
    end

    # Store raw payload
    simplefin_item.upsert_simplefin_snapshot!(accounts_data)

    # Import accounts - accounts_data[:accounts] is an array
    accounts_data[:accounts]&.each do |account_data|
      import_account(account_data)
    end
  end

  private

    def determine_sync_start_date
      # For the first sync, get all available data by using a very wide date range
      # When start_date is not provided, SimpleFin may only return recent transactions
      unless simplefin_item.last_synced_at
        # The SimpleFIN provider being used has a limit of 365 days.
        return 364.days.ago
      end

      # For subsequent syncs, fetch from last sync date with a buffer
      # Use 7 days buffer to ensure we don't miss any late-posting transactions
      simplefin_item.last_synced_at - 7.days
    end

    def import_account(account_data)
      Rails.logger.info "SimpleFin account_data: #{account_data.inspect}"
      # Import organization data from the account if present and not already imported
      if account_data[:org] && simplefin_item.institution_id.blank?
        import_organization(account_data[:org])
      end

      simplefin_account = simplefin_item.simplefin_accounts.find_or_initialize_by(
        account_id: account_data[:id]
      )

      # Store transactions temporarily
      transactions = account_data[:transactions]

      # Update account snapshot first (without transactions)
      simplefin_account.upsert_simplefin_snapshot!(account_data)

      # Then save transactions separately (so they don't get overwritten)
      if transactions && transactions.any?
        simplefin_account.update!(raw_transactions_payload: transactions)
      end
    end

    def import_organization(org_data)
      # Create normalized institution data for compatibility
      normalized_data = {
        id: org_data[:domain] || org_data[:"sfin-url"],
        name: org_data[:name] || extract_domain_name(org_data[:domain]),
        url: org_data[:domain] || org_data[:"sfin-url"],
        # Store the complete raw organization data
        raw_org_data: org_data
      }

      simplefin_item.upsert_simplefin_institution_snapshot!(normalized_data)
    end

    def extract_domain_name(domain)
      return "Unknown Institution" if domain.blank?

      # Extract a readable name from domain like "mybank.com" -> "Mybank"
      domain.split(".").first.capitalize
    end

    def handle_errors(errors)
      error_messages = errors.join(", ")

      if error_messages.include?("reauthenticate")
        simplefin_item.update!(status: :requires_update)
        return
      end

      raise Provider::Simplefin::SimplefinError.new(
        "SimpleFin API errors: #{error_messages}",
        :api_error
      )
    end
end
