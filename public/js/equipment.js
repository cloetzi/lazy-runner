import { mountNav } from "./nav.js";
import { mountEquipment } from "./equipment-list.js";

// The Equipment page: what you own, and its weights (equipment-list.js).

mountNav("equipment");
mountEquipment(document.getElementById("inventory")).load();
