RSpec.describe Exports::ExportDistributionsCSVService do
  let(:organization) { create(:organization) }

  describe '#generate_csv_data' do
    let(:generated_csv_data) { described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data }

    let(:item_category) { create(:item_category, name: "Test Category", organization: organization) }
    let(:duplicate_item) { create(:item, name: "Dupe Item", organization: organization, item_category: item_category) }

    let(:items_lists) do
      [
        [
          [duplicate_item, 5],
          [create(:item, organization: organization), 7],
          [duplicate_item, 3]
        ],

        *(Array.new(3) do |i|
          [[create(:item, organization: organization), i + 1]]
        end)
      ]
    end

    let(:item_names) { items_lists.flatten(1).map(&:first).map(&:name).sort.uniq }

    let(:distributions) do
      start_time = Time.current

      items_lists.each_with_index.map do |items, i|
        distribution = create(
          :distribution,
          issued_at: start_time - i.days, delivery_method: "shipped", shipping_cost: "12.09",
          organization: organization
        )

        items.each do |(item, quantity)|
          distribution.line_items << create(
            :line_item, quantity: quantity, item: item
          )
        end

        distribution
      end
    end

    let(:item_id) { duplicate_item.id }
    let(:item_name) { duplicate_item.name }
    let(:filters) { {by_item_id: item_id} }
    let(:all_org_items) { Item.where(organization:).uniq.sort_by { |item| item.name.downcase } }

    let(:total_item_quantities) do
      template = all_org_items.pluck(:name).index_with(0)

      items_lists.map do |items_list|
        row = template.dup
        items_list.each do |(item, quantity)|
          row[item.name] += quantity
        end
        row.values
      end
    end

    let(:non_item_headers) do
      [
        "Partner",
        "Initial Allocation",
        "Scheduled for",
        "Source Inventory",
        "Total Number of #{item_name}",
        "Total Value of #{item_name}",
        "Delivery Method",
        "Shipping Cost",
        "Status",
        "Agency Representative",
        "Comments"
      ]
    end

    let(:expected_headers) { non_item_headers + all_org_items.pluck(:name) }

    it 'should match the expected content for the csv' do
      expect(generated_csv_data[0]).to eq(expected_headers)

      distributions.zip(total_item_quantities).each_with_index do |(distribution, total_item_quantity), idx|
        row = [
          distribution.partner.name,
          distribution.created_at.strftime("%m/%d/%Y"),
          distribution.issued_at.strftime("%m/%d/%Y"),
          distribution.storage_location.name,
          distribution.line_items.where(item_id: item_id).total,
          distribution.cents_to_dollar(distribution.line_items.total_value),
          distribution.delivery_method,
          "$#{distribution.shipping_cost.to_f}",
          distribution.state,
          distribution.agency_rep,
          distribution.comment
        ]

        row += total_item_quantity

        expect(generated_csv_data[idx + 1]).to eq(row)
      end
    end

    context 'when items have different cases' do
      let(:item_names) { ["Zebra", "apple", "Banana"] }
      let(:expected_order) { ["apple", "Banana", "Zebra"] }
      let(:distribution) { create(:distribution, organization: organization) }
      let(:filters) { {} }
      let(:case_sensitive_csv_data) do
        # Create items in random order to ensure sort is working
        item_names.shuffle.each do |name|
          create(:item, name: name, organization: organization) 
        end
        
        described_class.new(distributions: [distribution], organization: organization, filters: filters).generate_csv_data
      end

      it 'should sort item columns case-insensitively, ASC' do
        # Get just the item columns by removing the known base headers
        item_columns = case_sensitive_csv_data[0] - non_item_headers
        item_columns = item_columns - ["Total Items", "Total Value"]
        
        # Check that the remaining columns match our expected case-insensitive sort
        expect(item_columns).to eq(expected_order)
      end
    end

    context 'when a new item is added' do
      let(:new_item_name) { "New Item" } # note that because of the case insensitive sort, we'll only get one of these
      let(:duplicate_item_name) { "new item" } # note that because of the case insensitive sort, we'll only get one of these
      let(:original_columns_count) { 15 }
      before do
        # if distributions are not created before new item
        # then additional records will be created
        distributions
        create(:item, name: new_item_name, organization: organization)
      end

      it 'should add it to the end of the row' do
        expect(generated_csv_data[0]).to eq(expected_headers)
          .and end_with(new_item_name)
          .and have_attributes(size: 17)
      end

      it 'should show up with a 0 quantity if there are none of this item in any distribution' do
        distributions.zip(total_item_quantities).each_with_index do |(distribution, total_item_quantity), idx|
          row = [
            distribution.partner.name,
            distribution.created_at.strftime("%m/%d/%Y"),
            distribution.issued_at.strftime("%m/%d/%Y"),
            distribution.storage_location.name,
            distribution.line_items.where(item_id: item_id).total,
            distribution.cents_to_dollar(distribution.line_items.total_value),
            distribution.delivery_method,
            "$#{distribution.shipping_cost.to_f}",
            distribution.state,
            distribution.agency_rep,
            distribution.comment
          ]

          row += total_item_quantity

          expect(generated_csv_data[idx + 1]).to eq(row)
            .and end_with(0)
            .and have_attributes(size: 17)
        end
      end
    end

    context 'when an organization\'s item exists but isn\'t in any distributions' do
      let(:unused_item) { create(:item, name: "Unused Item", organization: organization) }
      let(:generated_csv_data) do
        # Force unused_item to be created first
        unused_item
        described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
      end

      it 'should include the unused item as a column with 0 quantities' do
        expect(generated_csv_data[0]).to include(unused_item.name)
        
        distributions.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(unused_item.name)
          expect(row[item_column_index]).to eq(0)
        end
      end

    context 'when an organization\'s item is inactive' do
      let(:inactive_item) { create(:item, name: "Inactive Item", organization: organization, active: false) }
      let(:generated_csv_data) do
        # Force inactive_item to be created first
        inactive_item
        described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
      end

      it 'should include the inactive item as a column with 0 quantities' do
        expect(generated_csv_data[0]).to include(inactive_item.name)
        
        distributions.each_with_index do |_, idx|
          row = generated_csv_data[idx + 1]
          item_column_index = generated_csv_data[0].index(inactive_item.name)
          expect(row[item_column_index]).to eq(0)
        end
      end
    end
    end
    

    context 'when there are no distributions but the report is requested' do
      let(:generated_csv_data) { described_class.new(distributions: [], organization: organization, filters: filters).generate_csv_data }
      it 'returns a csv with only headers and no rows' do
        header_row = generated_csv_data[0]
        expect(header_row).to eq(expected_headers)
        expect(header_row.last).to eq(all_org_items.last.name)
        expect(generated_csv_data.size).to eq(1)
      end
    end

    context 'when generating CSV output' do
      let(:generated_csv) { described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv }

      it 'includes data for all distributions' do
        csv_rows = CSV.parse(generated_csv)
        expect(csv_rows.count).to eq(distributions.count + 1) # +1 for headers
      end
    end

    context 'with \'by_item_id\' filters applied' do
      let(:filters) { { by_item_id: duplicate_item.id } }
      let(:mock_totals) do
        totals = double('totals')
        allow(totals).to receive(:[]).and_return(double('distribution_total', quantity: 0, value: 0))
        totals
      end

      before do
        allow(DistributionTotalsService).to receive(:call)
          .with(Distribution.where(organization: organization).class_filter(filters))
          .and_return(mock_totals)
        allow_any_instance_of(described_class).to receive(:filtered_item_name).and_return(duplicate_item.name)
      end

      it 'passes filters to DistributionTotalsService' do
        described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(DistributionTotalsService).to have_received(:call).with(Distribution.where(organization: organization).class_filter(filters))
      end

      it 'updates the quantity column header when filtered by item' do
        csv_data = described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(csv_data[0]).to include("Total Number of #{duplicate_item.name}")
      end

      it 'updates the value column header when filtered by item' do
        csv_data = described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(csv_data[0]).to include("Total Value of #{duplicate_item.name}")
      end
    end

    context 'with \'by_item_category_id\' filters applied' do
      let(:filters) { { by_item_category_id: duplicate_item.item_category.id } }
      let(:mock_totals) do
        totals = double('totals')
        allow(totals).to receive(:[]).and_return(double('distribution_total', quantity: 0, value: 0))
        totals
      end

      before do
        allow(DistributionTotalsService).to receive(:call)
          .with(Distribution.where(organization: organization).class_filter(filters))
          .and_return(mock_totals)
        allow_any_instance_of(described_class).to receive(:filtered_item_name).and_return(duplicate_item.name)
      end

      it 'passes filters to DistributionTotalsService' do
        described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(DistributionTotalsService).to have_received(:call).with(Distribution.where(organization: organization).class_filter(filters))
      end

      it 'updates the quantity column header when filtered by item' do
        csv_data = described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(csv_data[0]).to include("Total Number of #{duplicate_item.item_category.name}")
      end

      it 'updates the value column header when filtered by item category' do
        csv_data = described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data
        expect(csv_data[0]).to include("Total Value of #{duplicate_item.item_category.name}")
      end

    end

    context 'with custom date formatting' do
      let(:generated_csv_data) { described_class.new(distributions: distributions, organization: organization, filters: filters).generate_csv_data }

      it 'formats created_at date as MM/DD/YYYY' do
        distribution_row = generated_csv_data[1] # First row after headers
        created_at_col = distribution_row[1]
        expect(created_at_col).to match(/\d{2}\/\d{2}\/\d{4}/)
      end

      it 'formats issued_at date as MM/DD/YYYY' do
        distribution_row = generated_csv_data[1]
        issued_at_col = distribution_row[2] 
        expect(issued_at_col).to match(/\d{2}\/\d{2}\/\d{4}/)
      end
    end
  end
end
