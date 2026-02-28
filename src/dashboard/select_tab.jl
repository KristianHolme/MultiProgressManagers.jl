"""
Experiment selector tab for folder mode.
Shows list of available database files.
"""

function _view_select_tab!(m::ProgressDashboard, area::Rect, buf)
    rows = split_layout(m.select_layout, area)
    length(rows) < 2 && return
    
    # Left: List of databases
    list_block = Block(
        title = " Experiments ",
        border_style = _pane_border(1),
        title_style = _pane_title(1)
    )
    list_area = render(list_block, rows[1], buf)
    
    # Build list items
    items = map(m.available_dbs) do db_path
        name = basename(db_path)
        # Try to get experiment count
        try
            count = length(Database.get_all_experiments(limit=1000))
            "$name ($count runs)"
        catch
            name
        end
    end
    
    selected = m.selected_db_index > 0 ? m.selected_db_index : 1
    list = SelectableList(items; selected = selected)
    render(list, list_area, buf)
    
    # Right: Preview of selected database
    preview_block = Block(
        title = " Preview ",
        border_style = _pane_border(2),
        title_style = _pane_title(2)
    )
    preview_area = render(preview_block, rows[2], buf)
    
    if m.selected_db_index > 0 && list_area.width >= 4
        _render_db_preview!(m, m.available_dbs[m.selected_db_index], preview_area, buf)
    end
    
    # Hints
    set_string!(buf, area.x, bottom(area), 
                "[↑↓]select  [Enter]open  [q]uit", 
                tstyle(:text_dim); max_x = right(area))
end

function _render_db_preview!(m::ProgressDashboard, db_path::String, area::Rect, buf)
    # Try to load database and show summary
    try
        # Switch to this DB temporarily
        current_db = Database.get_db()
        Database.close_db!()
        Database.init_db!(db_path)
        
        # Get stats
        stats = Database.get_experiment_stats(days=7)
        running = Database.get_running_experiments()
        
        y = area.y
        x = area.x
        
        set_string!(buf, x, y, "Path: $(db_path)", tstyle(:text); max_x = right(area))
        y += 2
        
        set_string!(buf, x, y, "Last 7 days:", tstyle(:accent, bold = true); max_x = right(area))
        y += 1
        set_string!(buf, x, y, "  Total: $(stats.total)", tstyle(:text); max_x = right(area))
        y += 1
        set_string!(buf, x, y, "  Completed: $(stats.completed)", tstyle(:success); max_x = right(area))
        y += 1
        set_string!(buf, x, y, "  Failed: $(stats.failed)", tstyle(:error); max_x = right(area))
        y += 1
        set_string!(buf, x, y, "  Running: $(stats.running)", tstyle(:warning); max_x = right(area))
        y += 2
        
        if !isempty(running)
            set_string!(buf, x, y, "Currently running:", tstyle(:accent, bold = true); max_x = right(area))
            y += 1
            for exp in running[1:min(3, length(running))]
                set_string!(buf, x, y, "  • $(exp.name)", tstyle(:text); max_x = right(area))
                y += 1
            end
            if length(running) > 3
                set_string!(buf, x, y, "  ... and $(length(running) - 3) more", tstyle(:text_dim); max_x = right(area))
            end
        end
        
        # Restore original DB
        Database.close_db!()
        if m.db_path !== nothing && !isempty(m.db_path)
            Database.init_db!(m.db_path)
        end
        
    catch e
        set_string!(buf, area.x, area.y, "Error loading: $(sprint(showerror, e))", 
                   tstyle(:error); max_x = right(area))
    end
end
