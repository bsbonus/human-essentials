require "csv" # other export specs already have it, but this one is special

RSpec.describe Exports::ExportProductDrivesCSVService do
  include ItemsHelper

  describe "#generate_csv_data" do
    let(:organization) { create(:organization) }
    let(:date_range) { Time.zone.today.all_month }
    subject { described_class.new(product_drives, organization, date_range).generate_csv }
    let(:duplicate_item) do
      FactoryBot.create(
        :item, name: Faker::Appliance.unique.equipment, organization: organization
      )
    end
    let(:items_lists) do
      [
        [
          [duplicate_item, 5],
          [
            FactoryBot.create(
              :item, name: Faker::Appliance.unique.equipment, organization: organization
            ),
            7
          ],
          [duplicate_item, 3]
        ],
        *(Array.new(3) do |i|
          [[FactoryBot.create(
            :item, name: Faker::Appliance.unique.equipment, organization: organization
          ), i + 1]]
        end)
      ]
    end

    let(:item_names) { items_lists.flatten(1).map(&:first).map(&:name).sort.uniq }

    let(:product_drives) do
      start_time = Time.current

      items_lists.each_with_index.map do |items, i|
        drive = create(
          :product_drive,
          organization: organization,
          name: "Drive #{i}",
          start_date: start_time + i.days,
          end_date: start_time + (i + 7).days,
          virtual: i.even?
        )

        items.each do |(item, quantity)|
          create(
            :donation,
            :with_items,
            item: item,
            item_quantity: quantity,
            organization: organization,
            product_drive: drive,
            issued_at: start_time + i.days
          )
        end

        drive
      end
    end

    let(:expected_headers) do
      [
        "Product Drive Name",
        "Start Date",
        "End Date",
        "Held Virtually?",
        "Quantity of Items",
        "Variety of Items",
        "In Kind Value"
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

    it "should match the expected content for the csv" do
      csv_rows = CSV.parse(subject)
      expect(csv_rows[0]).to eq(expected_headers)

      product_drives.zip(total_item_quantities).each_with_index do |(drive, total_item_quantity), idx|
        row = [
          drive.name,
          drive.start_date.strftime("%m-%d-%Y"),
          drive.end_date&.strftime("%m-%d-%Y"),
          drive.virtual ? "Yes" : "No",
          drive.donation_quantity_by_date(date_range).to_s,
          drive.distinct_items_count_by_date(date_range).to_s,
          dollar_value(drive.in_kind_value).to_s
        ]

        row += total_item_quantity.map(&:to_s)

        expect(csv_rows[idx + 1]).to eq(row)
      end
    end

    context "when an organization's item exists but isn't in any product drive" do
      let(:unused_item) { create(:item, name: "Unused Item", organization: organization) }
      let(:generated_csv_data) do
        # Force unused_item to be created first
        unused_item
        CSV.parse(described_class.new(product_drives, organization, date_range).generate_csv)
      end

      it "should include the unused item as a column with 0 quantities" do
        expect(generated_csv_data[0]).to include(unused_item.name)

        product_drives.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(unused_item.name)
          expect(row[item_column_index]).to eq("0")
        end
      end
    end

    context "when an organization's item is inactive" do
      let(:inactive_item) { create(:item, name: "Inactive Item", active: false, organization: organization) }
      let(:generated_csv_data) do
        # Force inactive_item to be created first
        inactive_item
        CSV.parse(described_class.new(product_drives, organization, date_range).generate_csv)
      end

      it "should include the inactive item as a column with 0 quantities" do
        expect(generated_csv_data[0]).to include(inactive_item.name)

        product_drives.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(inactive_item.name)
          expect(row[item_column_index]).to eq("0")
        end
      end
    end

    context "when generating CSV output" do
      let(:generated_csv) { described_class.new(product_drives, organization, date_range).generate_csv }

      it "returns a valid CSV string" do
        expect(generated_csv).to be_a(String)
        expect { CSV.parse(generated_csv) }.not_to raise_error
      end

      it "includes headers as first row" do
        csv_rows = CSV.parse(generated_csv)
        expect(csv_rows.first).to eq(expected_headers)
      end

      it "includes data for all product drives" do
        csv_rows = CSV.parse(generated_csv)
        expect(csv_rows.count).to eq(product_drives.count + 1) # +1 for headers
      end
    end

    context "when items have different cases" do
      let(:item_names) { ["Zebra", "apple", "Banana"] }
      let(:expected_order) { ["apple", "Banana", "Zebra"] }
      let(:product_drive) { create(:product_drive, organization: organization) }
      let(:case_sensitive_csv_data) do
        # Create items in random order to ensure sort is working
        item_names.shuffle.each do |name|
          create(:item, name: name, organization: organization)
        end

        CSV.parse(described_class.new([product_drive], organization, date_range).generate_csv)
      end

      it "should sort item columns case-insensitively, ASC" do
        # Get just the item columns by removing the known base headers
        item_columns = case_sensitive_csv_data[0].drop(7)  # Drop the first 7 base headers

        # Check that the remaining columns match our expected case-insensitive sort
        expect(item_columns).to eq(expected_order)
      end
    end
  end
end
