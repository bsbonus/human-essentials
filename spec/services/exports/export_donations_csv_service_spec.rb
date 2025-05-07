RSpec.describe Exports::ExportDonationsCSVService do
  describe '#generate_csv_data' do
    let(:organization) { create(:organization) }
    let(:generated_csv_data) { described_class.new(donation_ids: donation_ids, organization: organization).generate_csv_data }
    let(:donation_ids) { donations.map(&:id) }
    let(:duplicate_item) { create(:item, organization: organization) }
    let(:items_lists) do
      [
        [
          [duplicate_item, 5],
          [create(:item, organization: organization), 7],
          [duplicate_item, 3]
        ],
        *(Array.new(3) do |i|
          [[create(
            :item, name: "item_#{i}", organization: organization
          ), i + 1]]
        end)
      ]
    end

    let(:base_headers) do
      described_class.new(donation_ids: [], organization: organization).send(:base_headers)
    end

    let(:item_names) { items_lists.flatten(1).map(&:first).map(&:name).sort.uniq }

    let(:donations) do
      start_time = Time.current

      items_lists.each_with_index.map do |items, i|
        donation = create(
          :donation,
          organization: organization,
          donation_site: create(
            :donation_site, name: "Space Needle #{i}", organization: organization
          ),
          issued_at: start_time + i.days,
          comment: "This is the #{i}-th donation in the test."
        )

        items.each do |(item, quantity)|
          donation.line_items << create(
            :line_item, quantity: quantity, item: item
          )
        end

        donation
      end
    end

    let(:expected_headers) do
      [
        "Source",
        "Date",
        "Details",
        "Storage Location",
        "Quantity of Items",
        "Variety of Items",
        "In-Kind Value",
        "Comments"
      ] + expected_item_headers
    end

    let(:total_item_quantities) do
      template = item_names.index_with(0)

      items_lists.map do |items_list|
        row = template.dup
        items_list.each do |(item, quantity)|
          row[item.name] += quantity
        end
        row.values
      end
    end

    let(:expected_item_headers) do
      expect(item_names).not_to be_empty

      item_names
    end

    it 'should match the expected content for the csv' do
      expect(generated_csv_data[0]).to eq(expected_headers)

      donations.zip(total_item_quantities).each_with_index do |(donation, total_item_quantity), idx|
        row = [
          donation.source,
          donation.issued_at.strftime("%F"),
          donation.details,
          donation.storage_view,
          donation.line_items.total,
          total_item_quantity.count(&:positive?),
          donation.in_kind_value_money,
          donation.comment
        ]

        row += total_item_quantity

        expect(generated_csv_data[idx + 1]).to eq(row)
      end
    end

    context 'when an organization\'s item exists but isn\'t in any donation' do
      let(:unused_item) { create(:item, name: "Unused Item", organization: organization) }
      let(:generated_csv_data) do
        # Force unused_item to be created first
        unused_item
        described_class.new(donation_ids: donations.map(&:id), organization: organization).generate_csv_data
      end

      it 'should include the unused item as a column with 0 quantities' do
        expect(generated_csv_data[0]).to include(unused_item.name)

        donations.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(unused_item.name)
          expect(row[item_column_index]).to eq(0)
        end
      end
    end

    context 'when an organization\'s item is inactive' do
      let(:inactive_item) { create(:item, name: "Inactive Item", organization: organization, active: false) }
      let(:generated_csv_data) do
        # Force inactive_item to be created first
        inactive_item
        described_class.new(donation_ids: donations.map(&:id), organization: organization).generate_csv_data
      end

      it 'should include the inactive item as a column with 0 quantities' do
        expect(generated_csv_data[0]).to include(inactive_item.name)

        donations.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(inactive_item.name)
          expect(row[item_column_index]).to eq(0)
        end
      end
    end

    context 'when generating CSV output' do
      let(:generated_csv) { described_class.new(donation_ids: donation_ids, organization: organization).generate_csv }

      it 'returns a valid CSV string' do
        expect(generated_csv).to be_a(String)
        expect { CSV.parse(generated_csv) }.not_to raise_error
      end

      it 'includes headers as first row' do
        csv_rows = CSV.parse(generated_csv)
        expect(csv_rows.first).to eq(expected_headers)
      end

      it 'includes data for all donations' do
        csv_rows = CSV.parse(generated_csv)
        expect(csv_rows.count).to eq(donations.count + 1) # +1 for headers
      end
    end

    context 'when items have different cases' do
      let(:item_names) { ["Zebra", "apple", "Banana"] }
      let(:expected_order) { ["apple", "Banana", "Zebra"] }
      let(:donation) { create(:donation, organization: organization) }
      let(:case_sensitive_csv_data) do
        # Create items in random order to ensure sort is working
        item_names.shuffle.each do |name|
          create(:item, name: name, organization: organization)
        end

        described_class.new(donation_ids: [donation.id], organization: organization).generate_csv_data
      end

      it 'should sort item columns case-insensitively, ASC' do
        # Get just the item columns by removing the known base headers
        item_columns = case_sensitive_csv_data[0] - base_headers

        # Check that the remaining columns match our expected case-insensitive sort
        expect(item_columns).to eq(expected_order)
      end
    end
  end
end
