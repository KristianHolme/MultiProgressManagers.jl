"""
Stats tab - shows aggregate statistics and completion histogram.
"""

function _view_stats_tab!(m::ProgressDashboard, area::Rect, buf)
    rows = split_layout(m.stats_layout, area)
    length(rows) < 2 && return
    
    # === Top: Completion Histogram ===
    hist_block = Block(
        title = " Completion Distribution (10% bins) ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    hist_area = render(hist_block, rows[1], buf)
    
    # Calculate histogram
    histogram = Database.get_completion_histogram(m.db_handle, 10)
    m.completion_histogram = histogram
    
    if isempty(histogram) || sum(histogram) == 0
        set_string!(buf, hist_area.x, hist_area.y + 1, 
                   "No experiments to display", tstyle(:text_dim); 
                   max_x = right(hist_area))
    else
        # Build bar chart
        max_count = max(histogram...)
        
        bars = [
            BarEntry("0-10%", histogram[1]),
            BarEntry("10-20%", histogram[2]),
            BarEntry("20-30%", histogram[3]),
            BarEntry("30-40%", histogram[4]),
            BarEntry("40-50%", histogram[5]),
            BarEntry("50-60%", histogram[6]),
            BarEntry("60-70%", histogram[7]),
            BarEntry("70-80%", histogram[8]),
            BarEntry("80-90%", histogram[9]),
            BarEntry("90-100%", histogram[10]),
        ]
        
        chart = BarChart(bars; max_value = max_count)
        render(chart, hist_area, buf)
    end
    
    # === Bottom: Overall Statistics ===
    stats_block = Block(
        title = " Statistics (Last 7 Days) ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    stats_area = render(stats_block, rows[2], buf)
    
    # Refresh stats if needed (first load or every 30 seconds)
    if m.total_stats === nothing || (time() - m.last_stats_refresh > 30)
        m.total_stats = Database.get_experiment_stats(m.db_handle, days=7)
        m.last_stats_refresh = time()
    end
    
    if m.total_stats === nothing
        set_string!(buf, stats_area.x, stats_area.y + 1, 
                   "Loading statistics...", tstyle(:text_dim); 
                   max_x = right(stats_area))
    else
        stats = m.total_stats
        y = stats_area.y
        x = stats_area.x
        
        # Layout in columns
        col1_x = x
        col2_x = x + 25
        col3_x = x + 50
        
        # Handle missing values gracefully - convert to 0 for display
        total = coalesce(stats.total, 0)
        completed = coalesce(stats.completed, 0)
        failed = coalesce(stats.failed, 0)
        running = coalesce(stats.running, 0)
        
        # Row 1
        set_string!(buf, col1_x, y, "Total: $(total)", tstyle(:text); max_x = right(stats_area))
        set_string!(buf, col2_x, y, "Completed: $(completed)", tstyle(:success); max_x = right(stats_area))
        set_string!(buf, col3_x, y, "Failed: $(failed)", tstyle(:error); max_x = right(stats_area))
        y += 2
        
        # Row 2
        set_string!(buf, col1_x, y, "Running: $(running)", tstyle(:warning); max_x = right(stats_area))
        
        if stats.avg_duration_seconds !== nothing
            avg_dur = @sprintf("%.1f", stats.avg_duration_seconds / 60)
            set_string!(buf, col2_x, y, "Avg Duration: $(avg_dur) min", tstyle(:text); max_x = right(stats_area))
        end
        
        if total > 0
            success_rate = @sprintf("%.1f", 100 * completed / total)
            set_string!(buf, col3_x, y, "Success Rate: $(success_rate)%", tstyle(:accent); max_x = right(stats_area))
        end
        y += 2
        
        # Daily breakdown (from view)
        set_string!(buf, x, y, "Daily Summary:", tstyle(:accent, bold = true); max_x = right(stats_area))
        y += 1
        
        # Query daily stats
        try
            db = Database.ensure_open!(m.db_handle)
            daily = DBInterface.execute(db, """
                SELECT date, total_started, completed, failed, running
                FROM v_daily_experiments
                LIMIT 5
            """) |> DataFrame
            
            for row in eachrow(daily)
                if y > bottom(stats_area) - 1
                    break
                end
                line = "  $(row.date): $(row.total_started) started, $(row.completed) completed, $(row.failed) failed"
                set_string!(buf, x, y, line, tstyle(:text_dim); max_x = right(stats_area))
                y += 1
            end
        catch
            # View might not exist yet
        end
    end
    
    # Hints
    set_string!(buf, area.x, bottom(area), 
                "[r]efresh  [q]uit", 
                tstyle(:text_dim); max_x = right(area))
end
