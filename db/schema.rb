# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_12_03_230920) do
  create_table "cost_metrics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.text "metadata", default: "{}"
    t.integer "metric_type", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 12, scale: 6, null: false
    t.index ["date", "metric_type"], name: "index_cost_metrics_on_date_and_metric_type", unique: true
    t.index ["date"], name: "index_cost_metrics_on_date"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end
end
