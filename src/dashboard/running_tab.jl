"""
Running experiments tab - shows active experiments with real-time metrics.
"""

function _view_running_tab!(m::ProgressDashboard, area::Rect, buf)
    rows = split_layout(m.running_layout, area)
    length(rows) < 2 && return
    
    render_resize_handles!(buf, m.running_layout)
    
    # Split left pane into: table | summary
    left_rows = split_layout(m.running_left_layout, rows[1])
    length(left_rows) < 2 && return
    
    # === Top Left: Running Experiments Table ===
    table_block = Block(
        title = " Running Experiments ",
        border_style = _pane_border(1),
        title_style = _pane_title(1)
    )
    table_area = render(table_block, left_rows[1], buf)
    
    if isempty(m.running_experiments)
        set_string!(buf, table_area.x, table_area.y + 1, 
                   "No running experiments", tstyle(:text_dim); 
                   max_x = right(table_area))
    else
        # Build DataTable
        columns = [
            DataColumn("Name", 20, col_left),
            DataColumn("Progress", 10, col_center),
            DataColumn("ETA", 10, col_center),
            DataColumn("Short Speed", 12, col_center),
            DataColumn("Avg Speed", 12, col_center),
        ]
        
        data = map(m.running_experiments) do exp
            [
                exp.name,
                @sprintf("%.1f%%", exp.progress_pct),
                format_eta(exp.eta_seconds),
                format_speed(exp.short_avg_speed),
                format_speed(exp.total_avg_speed),
            ]
        end
        
        table = DataTable(columns, data; selected = m.selected_experiment)
        render(table, table_area, buf)
    end
    
    # === Bottom Left: Summary ===
    summary_block = Block(
        title = " Summary ",
        border_style = _pane_border(2),
        title_style = _pane_title(2)
    )
    summary_area = render(summary_block, left_rows[2], buf)
    
    if !isempty(m.running_experiments)
        total_exp = length(m.running_experiments)
        total_progress = sum(e -> e.current_step, m.running_experiments)
        total_steps = sum(e -> e.total_steps, m.running_experiments)
        overall_pct = total_steps > 0 ? 100 * total_progress / total_steps : 0
        
        y = summary_area.y
        x = summary_area.x
        
        set_string!(buf, x, y, "Experiments: $total_exp", tstyle(:text); max_x = right(summary_area))
        y += 1
        set_string!(buf, x, y, "Overall Progress: $(@sprintf("%.1f%%", overall_pct))", tstyle(:accent); max_x = right(summary_area))
        y += 1
        set_string!(buf, x, y, "Total Steps: $total_progress / $total_steps", tstyle(:text_dim); max_x = right(summary_area))
    end
    
    # === Right: Detail View ===
    detail_block = Block(
        title = " Detail ",
        border_style = _pane_border(2),
        title_style = _pane_title(2)
    )
    detail_area = render(detail_block, rows[2], buf)
    
    if m.selected_experiment > 0 && m.selected_experiment <= length(m.running_experiments)
        _render_experiment_detail!(m, m.running_experiments[m.selected_experiment], detail_area, buf)
    else
        set_string!(buf, detail_area.x, detail_area.y + 1, 
                   "Select an experiment to view details", tstyle(:text_dim); 
                   max_x = right(detail_area))
    end
end

function _render_experiment_detail!(m::ProgressDashboard, exp::ExperimentSummary, area::Rect, buf)
    y = area.y
    x = area.x
    max_x = right(area)
    
    # Name and status
    status_style = @match exp.status begin
        :running => tstyle(:warning)
        :completed => tstyle(:success)
        :failed => tstyle(:error)
        _ => tstyle(:text)
    end
    
    set_string!(buf, x, y, exp.name, tstyle(:accent, bold = true); max_x = max_x)
    y += 1
    set_string!(buf, x, y, "Status: $(string(exp.status))", status_style; max_x = max_x)
    y += 2
    
    # Progress bar (gauge)
    gauge_y = y
    gauge_height = 3
    if y + gauge_height <= bottom(area)
        gauge = Gauge(
            label = "Progress",
            value = exp.progress_pct / 100,
            show_percentage = true
        )
        render(gauge, Rect(x, y, area.width, gauge_height), buf)
        y += gauge_height + 1
    end
    
    # Metrics
    if y <= bottom(area)
        set_string!(buf, x, y, "ETA: $(format_eta(exp.eta_seconds))", tstyle(:text); max_x = max_x)
        y += 1
    end
    if y <= bottom(area)
        set_string!(buf, x, y, "Short Speed: $(format_speed(exp.short_avg_speed))", tstyle(:text); max_x = max_x)
        y += 1
    end
    if y <= bottom(area)
        set_string!(buf, x, y, "Avg Speed: $(format_speed(exp.total_avg_speed))", tstyle(:text); max_x = max_x)
        y += 1
    end
    if y <= bottom(area)
        started_str = ismissing(exp.started_at) ? "N/A" : string(exp.started_at)
        set_string!(buf, x, y, "Started: $(started_str)", tstyle(:text_dim); max_x = max_x)
        y += 2
    end
    
    # Sparkline of recent speed
    if !isempty(exp.sparkline) && y + 3 <= bottom(area)
        set_string!(buf, x, y, "Recent Speed Trend:", tstyle(:accent); max_x = max_x)
        y += 1
        
        sparkline = Sparkline(exp.sparkline)
        render(sparkline, Rect(x, y, area.width, 3), buf)
    end
end

# === Pane styling ===

function _pane_border(pane::Int)
    # No focus tracking yet, all use border style
    tstyle(:border)
end

function _pane_title(pane::Int)
    tstyle(:title, bold = true)
end
