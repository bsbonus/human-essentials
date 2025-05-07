module Exports
  class ExportDonationsCSVService
    def initialize(donation_ids:, organization:)
      # Use a where lookup so that I can eager load all the resources
      # needed rather than depending on external code to do it for me.
      # This makes this code more self contained and efficient!
      @organization = organization
      @donations = organization.donations.includes(
        :storage_location,
        :donation_site,
        :product_drive,
        :product_drive_participant,
        line_items: [:item]
      ).where(
        id: donation_ids,
      ).order(created_at: :asc)
      @item_headers = @organization.items.select("DISTINCT ON (LOWER(name)) items.name").order("LOWER(name) ASC").map(&:name)
    end

    def generate_csv
      csv_data = generate_csv_data

      CSV.generate(headers: true) do |csv|
        csv_data.each { |row| csv << row }
      end
    end

    def generate_csv_data
      csv_data = []

      csv_data << headers
      donations.each do |donation|
        csv_data << build_row_data(donation)
      end

      csv_data
    end

    private

    attr_reader :donations

    def headers
      # Build the headers in the correct order
      base_headers + item_headers
    end

    # Returns a Hash of keys to indexes so that obtaining the index
    # doesn't require a linear scan.
    def headers_with_indexes
      @headers_with_indexes ||= headers.each_with_index.to_h
    end

    # This method keeps the base headers associated with the lambdas
    # for extracting the values for the base columns from the given
    # donation.
    #
    # Doing so (as opposed to expressing them in distinct methods) makes
    # it less likely that a future edit will inadvertently modify the
    # order of the headers in a way that isn't also reflected in the
    # values for the these base columns.
    #
    # Reminder: Since Ruby 1.9, Hashes are ordered based on insertion
    # (or on the order of the literal).
    def base_table
      {
        "Source" => ->(donation) {
          donation.source
        },
        "Date" => ->(donation) {
          donation.issued_at.strftime("%F")
        },
        "Details" => ->(donation) {
          donation.details
        },
        "Storage Location" => ->(donation) {
          donation.storage_view
        },
        "Quantity of Items" => ->(donation) {
          donation.line_items.total
        },
        "Variety of Items" => ->(donation) {
          donation.line_items.map(&:name).uniq.size
        },
        "In-Kind Value" => ->(donation) {
          donation.in_kind_value_money
        },
        "Comments" => ->(donation) {
          donation.comment
        }
      }
    end

    def base_headers
      base_table.keys
    end

    attr_reader :item_headers

    def build_row_data(donation)
      row = base_table.values.map { |closure| closure.call(donation) }

      row += Array.new(item_headers.size, 0)

      donation.line_items.each do |line_item|
        item_name = line_item.item.name
        item_column_idx = headers_with_indexes[item_name]
        row[item_column_idx] += line_item.quantity
      end

      row
    end
  end
end
