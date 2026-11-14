require_relative "../lib/api_reference"

Rage.routes.draw do
  # The API described from the controller comments: a browsable page
  # (lib/api_reference.rb), and the OpenAPI document at /api/openapi/json.
  mount ApiReference.new(Rage.openapi.application), at: "/api/openapi"
  # The MCP server for an assistant acting as a personal trainer
  # (app/mcp/trainer_mcp.rb). Signed in with a personal API token.
  mount TrainerMcp.app, at: "/mcp"

  namespace :api do
    get "today", to: "today#show"
    get "version", to: "version#show"
    get "me", to: "me#show"
    get "account/devices", to: "devices#index"
    delete "account/devices", to: "devices#destroy_others"
    delete "account/devices/:id", to: "devices#destroy"
    get "account/tokens", to: "tokens#index"
    post "account/tokens", to: "tokens#create"
    delete "account/tokens/:id", to: "tokens#destroy"
    get "account/identities", to: "identities#index"
    delete "account/identities/:id", to: "identities#destroy"
    post "account/welcome", to: "welcome#create"
    get "users", to: "users#index"
    delete "users/:id", to: "users#destroy"
    post "users/:id/password", to: "users#reset_password"
    get "invites", to: "invites#index"
    post "invites", to: "invites#create"
    delete "invites/:id", to: "invites#destroy"
    get "settings", to: "settings#show"
    patch "settings", to: "settings#update"
    resources :exercises, only: %i[index show]
    get "exercises/:id/alternatives", to: "exercises#alternatives"
    resources :equipment, only: %i[index update]
    get "exercises/:id/weight", to: "exercise_weights#show"
    put "exercises/:id/weight", to: "exercise_weights#update"
    patch "exercises/:id/weight", to: "exercise_weights#update"
    resources :programs, only: %i[index]
    get "examples", to: "examples#index"
    post "examples/:slug/import", to: "examples#import"
    resources :workouts, only: %i[index show create destroy]
    patch "workouts/:id", to: "workouts#update"
    put "workouts/:id", to: "workouts#replace"
    post "workouts/:id/duplicate", to: "workouts#duplicate"
    resources :sessions, only: %i[index show create update destroy]
    post "sessions/:id/sets", to: "sessions#sets"
    post "sessions/:id/complete", to: "sessions#complete"
    patch "sessions/:id/completion", to: "sessions#completion"
    resources :activities, only: %i[index create destroy]
    patch "activities/:id", to: "activities#update"
    get "calendar", to: "calendar#show"
    resources :routines, only: %i[index create destroy]
    patch "routines/:id", to: "routines#update"
    put "routines/:id/days/:date", to: "routines#update_day"
    delete "routines/:id/days/:date", to: "routines#reset_day"
    resources :goals, only: %i[index create destroy]
    patch "goals/:id", to: "goals#update"
    post "goals/:id/accept", to: "goals#accept"
    post "goals/:id/dismiss", to: "goals#dismiss"
    get "coach", to: "coach#show"
    get "coach/notes", to: "coach#notes"
    post "coach/notes", to: "coach#create_note"
    patch "coach/notes/:id", to: "coach#update_note"
    delete "coach/notes/:id", to: "coach#destroy_note"
    get "history", to: "history#show"
    get "history/exercises", to: "history#exercises"
    get "exercises/:id/history", to: "history#exercise"
  end
end
