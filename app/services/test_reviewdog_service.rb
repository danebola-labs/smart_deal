# frozen_string_literal: true

# This is a test file to demonstrate Reviewdog code review
# DELETE THIS FILE AFTER TESTING
class TestReviewdogService
  def bad_method
    x=1+2
    y =  3
    if x==3
      puts "hello"
    end
    return y
  end

  def another_bad_method(user_input)
    # Potential SQL injection - Brakeman should catch this
    query = "SELECT * FROM users WHERE name = '#{user_input}'"
    puts query
  end

  def unused_variable
    foo = "bar"
    baz = "qux"
    puts baz
  end
end
