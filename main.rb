#!/usr/bin/ruby

require 'gtk3'
require 'pdf-reader'
require 'hexapdf'
require 'uri'

class PdfMetadataEditor < Gtk::Window
  def initialize
    super("PDF Metadata Editor")
    signal_connect("destroy") { Gtk.main_quit }

    set_default_size(700, 560)
    set_size_request(700, 560)
    set_resizable(false)
    set_border_width(10)

    main_vbox = Gtk::Box.new(:vertical, 5)
    add(main_vbox)

    @status_label = Gtk::Label.new("Drag and drop a PDF here, or click 'Select PDF'.")
    @status_label.set_margin_bottom(10)
    main_vbox.pack_start(@status_label, :expand => false, :fill => false, :padding => 0)

    @content_area = Gtk::ScrolledWindow.new
    main_vbox.pack_start(@content_area, :expand => true, :fill => true, :padding => 0)

    metadata_frame = Gtk::Frame.new("PDF Metadata")
    metadata_frame.set_margin_top(10)
    metadata_frame.set_margin_bottom(10)
    metadata_frame.set_shadow_type(:in)
    @content_area.add(metadata_frame)

    @metadata_grid = Gtk::Grid.new
    @metadata_grid.set_column_spacing(10)
    @metadata_grid.set_row_spacing(5)
    @metadata_grid.set_margin_start(10)
    @metadata_grid.set_margin_end(10)
    @metadata_grid.set_margin_top(10)
    @metadata_grid.set_margin_bottom(10)
    metadata_frame.add(@metadata_grid)

    @metadata_entries = {}

    fields = [
      { key: :Title, label: "Title:" },
      { key: :Author, label: "Author:" },
      { key: :Subject, label: "Subject:" },
      { key: :Keywords, label: "Keywords:" },
      { key: :Creator, label: "Creator:" },
      { key: :Producer, label: "Producer:" },
      { key: :CreationDate, label: "Creation Date:" },
      { key: :ModDate, label: "Modification Date:" }
    ]

    fields.each_with_index do |field, index|
      label = Gtk::Label.new(field[:label])
      label.set_xalign(0)
      entry = Gtk::Entry.new
      entry.set_hexpand(true)
      @metadata_grid.attach(label, 0, index, 1, 1)
      @metadata_grid.attach(entry, 1, index, 1, 1)
      @metadata_entries[field[:key]] = entry
    end

    button_box = Gtk::Box.new(:horizontal, 5)
    main_vbox.pack_start(button_box, :expand => false, :fill => false, :padding => 0)

    select_pdf_button = Gtk::Button.new(label: "Select PDF")
    select_pdf_button.signal_connect("clicked") { on_select_pdf_clicked }
    select_pdf_button.set_tooltip_text("Select a PDF file to edit its metadata (Ctrl+O)")
    button_box.pack_start(select_pdf_button, :expand => false, :fill => false, :padding => 5)

    @save_button = Gtk::Button.new(label: "Save Changes")
    @save_button.sensitive = false
    @save_button.signal_connect("clicked") { on_save_changes_clicked }
    @save_button.set_tooltip_text("Save changes to the PDF metadata (Ctrl+S)")
    button_box.pack_start(@save_button, :expand => false, :fill => false, :padding => 5)

    @extra_button = Gtk::Button.new(label: "Extra Functions")
    @extra_button.signal_connect("clicked") { on_extra_functions_clicked }
    @extra_button.set_tooltip_text("Access additional functions like clearing metadata or viewing program info (F1)")
    button_box.pack_end(@extra_button, :expand => false, :fill => false, :padding => 5)

    show_all

    add_events([:button_press_mask, :button_release_mask, :pointer_motion_mask,
                :exposure_mask, :key_press_mask, :key_release_mask,
                :structure_mask, :focus_change_mask, :property_change_mask,
                :visibility_notify_mask, :scroll_mask])
    self.drag_dest_set(Gtk::DestDefaults::ALL, [Gtk::TargetEntry.new("text/uri-list", 0, 0)], Gdk::DragAction::COPY)
    signal_connect("drag-data-received") do |widget, drag_context, x, y, data, info, time|
      on_drag_data_received(data)
    end

    signal_connect("key-press-event") do |widget, event|
      on_key_press(event)
    end
  end

  def on_key_press(event)
    if event.keyval == Gdk::Keyval::KEY_o && event.state.control_mask?
      on_select_pdf_clicked
      true
    elsif event.keyval == Gdk::Keyval::KEY_s && event.state.control_mask?
      on_save_changes_clicked
      true
    elsif event.keyval == Gdk::Keyval::KEY_l && event.state.control_mask?
      clear_all_metadata_fields
      true
    elsif event.keyval == Gdk::Keyval::KEY_F1
      show_about_dialog
      true
    end
    false
  end

  def on_select_pdf_clicked
    dialog = Gtk::FileChooserDialog.new(
      title: "Select PDF File",
      parent: self,
      action: :open,
      buttons: [[Gtk::Stock::CANCEL, :cancel], [Gtk::Stock::OPEN, :accept]]
    )
    filter = Gtk::FileFilter.new
    filter.name = "PDF Files"
    filter.add_pattern("*.pdf")
    dialog.add_filter(filter)

    if dialog.run == :accept
      file_path = dialog.filename
      load_pdf(file_path)
    end
    dialog.destroy
  end

  def on_save_changes_clicked
    return unless @current_pdf_path

    begin
      doc = HexaPDF::Document.open(@current_pdf_path)
      info = doc.trailer.info

      @metadata_entries.each do |key, entry|
        info[key] = entry.text unless entry.text.empty?
        info.delete(key) if entry.text.empty?
      end
      doc.write(@current_pdf_path)
      update_status_and_revert("Metadata saved to: #{@current_pdf_path}")
    rescue HexaPDF::Error => e
      update_status_and_revert("Error saving PDF (HexaPDF error): #{e.message}")
    rescue StandardError => e
      update_status_and_revert("An unexpected error occurred while saving: #{e.message}")
    end
  end

  def on_extra_functions_clicked
    menu = Gtk::Menu.new

    clear_metadat_item = Gtk::MenuItem.new(label: "Clear All Metadata Fields")
    clear_metadat_item.signal_connect("activate") { on_clear_metadata_confirmed }
    menu.append(clear_metadat_item)

    about_item = Gtk::MenuItem.new(label: "About")
    about_item.signal_connect("activate") { show_about_dialog }
    menu.append(about_item)

    menu.show_all
    menu.popup_at_widget(@extra_button, Gdk::Gravity::SOUTH_WEST, Gdk::Gravity::NORTH_WEST, nil)
  end

  def on_clear_metadata_confirmed
    dialog = Gtk::MessageDialog.new(
      parent: self,
      flags: :modal,
      type: :question,
      buttons: :yes_no,
      message: "Are you sure you want to clear all metadata fields? This action cannot be undone."
    )
    response = dialog.run
    dialog.destroy

    if response == :yes
      clear_all_metadata_fields_action
    end
  end

  def clear_all_metadata_fields_action
    @metadata_entries.each { |key, entry| entry.text = "" }
    update_status_and_revert("All metadata fields cleared.")
  end

  def show_about_dialog
    dialog = Gtk::AboutDialog.new
    dialog.set_program_name("PDF Metadata Editor")
    dialog.set_version("1.0")
    dialog.set_copyright("© 2025 John Breno")
    dialog.set_comments("é um simple editor  metadata de PDF que usa GTK3.")
    dialog.set_website("https://github.com/John-BrenoF/pdf-metadata-editor.git")
    dialog.set_license(<<~LICENSE_TEXT
MIT License

Copyright (c) 2025 John Breno

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICENSE_TEXT
    )
    dialog.run
    dialog.destroy
  end

  def on_drag_data_received(data)
    uris = data.uris
    if uris && !uris.empty?
      file_path = URI.decode_www_form_component(uris.first.sub("file://", ""))
      load_pdf(file_path)
    end
  end

  def load_pdf(file_path)
    @current_pdf_path = file_path
    @status_label.set_text("Loading: #{file_path}")
    begin
      doc = HexaPDF::Document.open(file_path)
      info = doc.trailer.info

      @metadata_entries.each do |key, entry|
        entry.text = info[key].to_s
      end
      update_status_and_revert("Loaded: #{file_path}")
      @save_button.sensitive = true
    rescue HexaPDF::Error => e
      update_status_and_revert("Error loading PDF (HexaPDF error): #{e.message}")
      @save_button.sensitive = false
      @metadata_entries.each { |key, entry| entry.text = "" }
    rescue Errno::ENOENT
      update_status_and_revert("Error: File not found.")
      @save_button.sensitive = false
      @metadata_entries.each { |key, entry| entry.text = "" }
    rescue StandardError => e
      update_status_and_revert("An unexpected error occurred: #{e.message}")
      @save_button.sensitive = false
      @metadata_entries.each { |key, entry| entry.text = "" }
    end
  end

  def update_status_and_revert(message, delay_ms = 3000)
    original_text = @status_label.text
    @status_label.set_text(message)
    GLib::Timeout.add(delay_ms) do
      @status_label.set_text(original_text)
      false
    end
  end
end

window = PdfMetadataEditor.new
Gtk.main
