module ApplicationHelper
  def number_to_human_size(size)
    return "0 B" if size.nil? || size == 0
    
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    unit = 0
    size_float = size.to_f
    
    while size_float >= 1024 && unit < units.length - 1
      size_float /= 1024.0
      unit += 1
    end
    
    "#{size_float.round(2)} #{units[unit]}"
  end
end
